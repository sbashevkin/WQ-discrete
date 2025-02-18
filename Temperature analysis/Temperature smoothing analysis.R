require(gstat)
require(sp)
require(spacetime)
library(tidyverse)
library(discretewq)
library(mgcv)
library(lubridate)
library(hms)
library(sf)
library(stars)
require(patchwork)
require(geofacet)
require(dtplyr)
require(scales)
require(parallel)
source("Utility_functions.R")

# Function to extract scat family variables

scat_extract<-function(model){
  
  theta<-get(".Theta", envir=environment(model$family$rd))
  min.df <- get(".min.df", envir=environment(model$family$rd))
  nu <- exp(theta[1]) + min.df
  sig <- exp(theta[2])
  return(c(nu=nu, sig=sig))
}


# Data preparation --------------------------------------------------------

is.even <- function(x) as.integer(x) %% 2 == 0

# Load Delta Shapefile from Brian
Delta<-st_read("Delta Subregions")%>%
  filter(!SubRegion%in%c("South Bay", "San Francisco Bay", "San Pablo Bay", "Upper Yolo Bypass", 
                         "Upper Napa River", "Lower Napa River", "Carquinez Strait"))%>% # Remove regions outside our domain of interest
  dplyr::select(SubRegion)

# Load data
Data <- wq()%>%
  filter(!is.na(Temperature) & !is.na(Datetime) & !is.na(Latitude) & !is.na(Longitude) & !is.na(Date))%>% #Remove any rows with NAs in our key variables
  filter(Temperature !=0)%>% #Remove 0 temps
  mutate(Temperature_bottom=if_else(Temperature_bottom>30, NA_real_, Temperature_bottom))%>% #Remove bad bottom temps
  filter(hour(Datetime)>=5 & hour(Datetime)<=20)%>% # Only keep data between 5AM and 8PM
  mutate(Datetime = with_tz(Datetime, tz="America/Phoenix"), #Convert to a timezone without daylight savings time
         Date = with_tz(Date, tz="America/Phoenix"),
         Time=as_hms(Datetime), # Create variable for time-of-day, not date. 
         Noon_diff=abs(hms(hours=12)-Time))%>% # Calculate difference from noon for each data point for later filtering
  group_by(Station, Source, Date)%>%
  filter(Noon_diff==min(Noon_diff))%>% # Select only 1 data point per station and date, choose data closest to noon
  filter(Time==min(Time))%>% # When points are equidistant from noon, select earlier point
  ungroup()%>%
  distinct(Date, Station, Source, .keep_all = TRUE)%>% # Finally, remove the ~10 straggling datapoints from the same time and station
  st_as_sf(coords=c("Longitude", "Latitude"), crs=4326, remove=FALSE)%>% # Convert to sf object
  st_transform(crs=st_crs(Delta))%>% # Change to crs of Delta
  st_join(Delta, join=st_intersects)%>% # Add subregions
  filter(!is.na(SubRegion))%>% # Remove any data outside our subregions of interest
  mutate(Julian_day = yday(Date), # Create julian day variable
         Month_fac=factor(Month), # Create month factor variable
         Source_fac=factor(Source),
         Year_fac=factor(Year))%>% 
  mutate(Date_num = as.numeric(Date))%>%  # Create numeric version of date for models
  mutate(Time_num=as.numeric(Time)) # Create numeric version of time for models (=seconds since midnight)


# Pull station locations for major monitoring programs
# This will be used to set a boundary for this analysis focused on well-sampled regions.
WQ_stations<-Data%>%
  st_drop_geometry()%>%
  filter(Source%in%c("FMWT", "STN", "SKT", "20mm", "EMP", "Suisun"))%>%
  group_by(StationID, Source, Latitude, Longitude)%>%
  summarise(N=n(), .groups="drop")%>% # Calculate how many times each station was sampled
  filter(N>50 & !StationID%in%c("20mm 918", "STN 918"))%>% # Only keep stations sampled >50 times when deciding which regions to retain. 
  # "20mm 918", "STN 918" are far south of the rest of the well-sampled sites and are not sampled year round, so we're removing them to exclude that far southern region
  st_as_sf(coords=c("Longitude", "Latitude"), crs=4326, remove=FALSE)%>% # Convert to sf object
  st_transform(crs=st_crs(Delta))%>%
  st_join(Delta) # Add subregions

# Remove any subregions that do not contain at least one of these >50 samples stations from the major monitoring programs
Delta <- Delta%>%
  filter(SubRegion%in%unique(WQ_stations$SubRegion) | SubRegion=="Georgiana Slough") # Retain Georgiana Slough because it's surrounded by well-sampled regions
# Visualize sampling regions of major surveys

# Now filter data to only include this final set of subregions, and any stations outside the convex hull formed by the >50 samples stations from the major monitoring programs
Data<-Data%>%
  filter(SubRegion%in%unique(Delta$SubRegion))%>%
  st_join(WQ_stations%>%
            st_union()%>%
            st_convex_hull()%>% # Draws a hexagram or pentagram or similar around the outer-most points
            st_as_sf()%>%
            mutate(IN=TRUE),
          join=st_intersects)%>%
  filter(IN)%>%
  dplyr::select(-IN)%>%
  mutate(Group=if_else(is.even(Year), 1, 2))%>%
  mutate_at(vars(Date_num, Longitude, Latitude, Time_num, Year, Julian_day), list(s=~(.-mean(., na.rm=T))/sd(., na.rm=T))) # Create centered and standardized versions of covariates

#saveRDS(Data, file="Temperature analysis/Discrete Temp Data.Rds")
Data<-readRDS("Temperature analysis/Discrete Temp Data.Rds")

# Model selection ---------------------------------------------------------


# Chose separate smoothers for each year in order to ensure the most accurate predictions since temperatures fluctuate year-to-year
# Tried including a global smoother for lat, long, & julian_day, but ran into issues with curvilinearity.
# Optimized k-values using BIC comparisons on models fit to the even years of the dataset as follows: 

# Gavin Simpson recommends using AIC, not BIC https://stackoverflow.com/questions/59825442/get-the-aic-or-bic-citerium-from-a-gamm-gam-and-lme-models-how-in-mgcv-and-h

## New best
modellda <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("tp", "cc"), k=c(25, 20), by=Year_fac) + 
                  te(Time_num_s, Julian_day_s, bs=c("tp", "cc"), k=c(5, 12)),
                data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)

#AIC: 120728.7
#BIC: 162087.7
## New best

modellda.2 <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("tp", "cc"), k=c(25, 20), by=Year_fac) + 
                    te(Time_num_s, Julian_day_s, bs=c("tp", "cc"), k=c(5, 12)), select=TRUE,
                  data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)
#AIC: 120729.9
#BIC: 161957.2

modelld2a <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("tp", "cc"), k=c(25, 10), by=Year_fac) + 
                   te(Time_num_s, Julian_day_s, bs=c("tp", "cc"), k=c(5, 12)),
                 data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)

#AIC: 141331.1
#BIC: 163732.6

modelld3a <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("tp", "cc"), k=c(15, 20), by=Year_fac) + 
                   te(Time_num_s, Julian_day_s, bs=c("tp", "cc"), k=c(5, 12)),
                 data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)

#AIC: 122571.1
#BIC: 155211

modelld4a <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("tp", "cc"), k=c(25, 20), by=Year_fac) + 
                   te(Time_num_s, Julian_day_s, bs=c("tp", "cc"), k=c(5, 6)),
                 data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)

#AIC: 120732.4
#BIC: 162066.7

modelld5a <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("tp", "cc"), k=c(15, 20), by=Year_fac) + 
                   te(Time_num_s, Julian_day_s, bs=c("tp", "cc"), k=c(5, 6)),
                 data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)
#AIC: 122602.9
#BIC: 155149.3

modelld6a <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("tp", "cc"), k=c(15, 10), by=Year_fac) + 
                   te(Time_num_s, Julian_day_s, bs=c("tp", "cc"), k=c(5, 6)),
                 data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=3)
#AIC: 142605.2
#BIC: 159811.1

modelld7a <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("tp", "cc"), k=c(10, 20), by=Year_fac) + 
                   te(Time_num_s, Julian_day_s, bs=c("tp", "cc"), k=c(5, 6)),
                 data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=3)

#AIC: 123986.6
#BIC: 149802.3

modelld8a <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("tp", "cc"), k=c(5, 20), by=Year_fac) + 
                   te(Time_num_s, Julian_day_s, bs=c("tp", "cc"), k=c(5, 6)),
                 data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=3)
#AIC: 132112.5
#BIC: 147318.7

modelld9a <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("tp", "cc"), k=c(40, 20), by=Year_fac) + 
                   te(Time_num_s, Julian_day_s, bs=c("tp", "cc"), k=c(5, 12)),
                 data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)

#AIC: 119485.3
#BIC: 167776.6

modelld10a <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("tp", "cc"), k=c(25, 30), by=Year_fac) + 
                    te(Time_num_s, Julian_day_s, bs=c("tp", "cc"), k=c(5, 12)),
                  data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)

#AIC: 105217.7
#BIC: 162644

modelld11a <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("tp", "cc"), k=c(25, 20), by=Year_fac) + 
                    te(Time_num_s, Julian_day_s, bs=c("tp", "cc"), k=c(5, 24)),
                  data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)

#AIC: 120166.2
#BIC: 162078.2

modelld12a <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("tp", "cc"), k=c(50, 20), by=Year_fac) + 
                    te(Time_num_s, Julian_day_s, bs=c("tp", "cc"), k=c(5, 12)),
                  data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)

AIC(modelld12a)
BIC(modelld12a)

modelld13a <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("tp", "cc"), k=c(25, 40), by=Year_fac) + 
                    te(Time_num_s, Julian_day_s, bs=c("tp", "cc"), k=c(5, 12)),
                  data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)

AIC(modelld13a)
BIC(modelld13a)

modelld14a <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(25, 20), by=Year_fac) + 
                    te(Time_num_s, Julian_day_s, bs=c("cr", "cc"), k=c(5, 12)),
                  data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=5)
#AIC: 120739.6
#BIC: 162099.7

modelld15a <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(20, 13), by=Year_fac) + 
                    te(Time_num_s, Julian_day_s, bs=c("cr", "cc"), k=c(5, 13)),
                  data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=5)
#AIC: 134736
#BIC: 160746

modellea <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(20, 13), by=Year_fac) + 
                  te(Time_num_s, Julian_day_s, bs=c("cr", "cc"), k=c(5, 13)), family=scat,
                data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=3)
#AIC: 126403.2
#BIC: 156933.8

modellea2 <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(30, 13), by=Year_fac) + 
                   te(Time_num_s, Julian_day_s, bs=c("cr", "cc"), k=c(5, 13)), family=scat,
                 data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=3)
# 4: In bgam.fitd(G, mf, gp, scale, nobs.extra = 0, rho = rho, coef = coef,  :
#                  algorithm did not converge

modellea3 <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(30, 13), by=Year_fac) + 
                   s(Time_num_s, bs="cr", k=5), family=scat, control=list(trace=TRUE),
                 data = Data, method="fREML", discrete=T, nthreads=8)

cl <- makeCluster(8) 
modellea3B <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(30, 13), by=Year_fac) + 
                    s(Time_num_s, bs="cr", k=5), family=scat, control=list(trace=TRUE),
                  data = Data, method="REML", discrete=F, cluster=cl)
# Didn't go anywhere in a few hours


modellea3C <- gam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(30, 13), by=Year_fac) + 
                    s(Time_num_s, bs="cr", k=5), family=scat, control=list(trace=TRUE, nthreads=8),
                  data = Data, method="REML", optimizer=c("outer","bfgs"))


modellea3a <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(15, 13), by=Year_fac) + 
                    s(Time_num_s, bs="cr", k=5), family=scat, control=list(trace=TRUE),
                  data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)

modellea3a_vars<-scat_extract(modellea3a)


modellea3a2 <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(20, 13), by=Year_fac) + 
                     s(Time_num_s, bs="cr", k=5), family=scat, control=list(trace=TRUE),
                   data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)

modellea3a2_vars<-scat_extract(modellea3a2)

theta<-get(".Theta", envir=environment(modellea3$family$rd))
min.df <- get(".min.df", envir=environment(modellea3$family$rd))
nu <- exp(theta[1]) + min.df
sig <- exp(theta[2])

modellea3a3 <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(30, 13), by=Year_fac) + 
                     s(Time_num_s, bs="cr", k=5), family=scat, control=list(trace=TRUE),
                   data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)
# algorithm did not converge

modellea3a3_vars<-scat_extract(modellea3a3)

modellea3a4 <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(25, 13), by=Year_fac) + 
                     s(Time_num_s, bs="cr", k=5), family=scat, control=list(trace=TRUE),
                   data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)

modellea3a4_vars<-scat_extract(modellea3a4)

modellea3a4_gaus <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(25, 13), by=Year_fac) + 
                          s(Time_num_s, bs="cr", k=5), control=list(trace=TRUE),
                        data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)

modellea3b4 <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(25, 13), by=Year_fac) + 
                     s(Time_num_s, bs="cr", k=5), family=scat, control=list(trace=TRUE),
                   data = filter(Data, Group==2)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)

modellea3b4_vars<-scat_extract(modellea3b4)

modellea3b4_gaus <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(25, 13), by=Year_fac) + 
                          s(Time_num_s, bs="cr", k=5), control=list(trace=TRUE),
                        data = filter(Data, Group==2)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=7)

scat_vars_final<-map2_dbl(modellea3a4_vars, modellea3b4_vars, ~mean(c(.x, .y)))

modellea_full <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(25, 13), by=Year_fac) + 
                       s(Time_num_s, bs="cr", k=5), family=scat(theta=scat_vars_final), control=list(trace=TRUE),
                     data = Data, method="fREML", discrete=T, nthreads=8)

#Error: cannot allocate vector of size 1.8 Gb
# In addition: Warning message:
#  In scat(theta = scat_vars_final) : Supplied df below min.df. min.df reset

modellea3b <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(30, 12), by=Year_fac) + 
                    s(Time_num_s, bs="cr", k=5), family=scat, control=list(trace=TRUE),
                  data = filter(Data, Group==2)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=4)

modellea4 <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(50, 13), by=Year_fac) + 
                   s(Time_num_s, bs="cr", k=5), family=scat,
                 data = filter(Data, Group==1)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=4)
# Error: cannot allocate vector of size 928.8 Mb

cl <- makeCluster(8) 
modellea3_full <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(30, 13), by=Year_fac) + 
                        s(Time_num_s, bs="cr", k=5), family=scat, control=list(trace=TRUE),
                      data = Data, method="fREML", discrete=F, cluster=cl)
# Ran out of memory after first step

modellea3_full <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(30, 13), by=Year_fac) + 
                        s(Time_num_s, bs="cr", k=5), family=scat, control=list(trace=TRUE),
                      data = Data, method="fREML", discrete=T, cluster=cl)
# Got to second step but no parallel processing

modellea3_full <- gam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(30, 13), by=Year_fac) + 
                        s(Time_num_s, bs="cr", k=5), family=scat, control=list(trace=TRUE, nthreads=8),
                      data = Data, method="REML")

modellea3_full <- gamm(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(30, 13), by=Year_fac) + 
                         s(Time_num_s, bs="cr", k=5), family=scat, control=list(trace=TRUE, nthreads=8),
                       data = Data, method="REML")
# Error: cannot allocate vector of size 624 Kb 


# Try fixing scat arguments
modellea3_full <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(30, 13), by=Year_fac) + 
                        s(Time_num_s, bs="cr", k=5), family=scat(theta=c(3, 0.5200804)), control=list(trace=TRUE),
                      data = Data, method="fREML", discrete=T, nthreads=8)
# This works!


# Trying to set the scat parameters as starting values instead of fixed values to see if this works better
modellea3_full2 <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(30, 13), by=Year_fac) + 
                         s(Time_num_s, bs="cr", k=5), family=scat(theta=c(-3, -0.5200804)), control=list(trace=TRUE),
                       data = Data, method="fREML", discrete=T, nthreads=8)
# Taking forever

# Final model -------------------------------------------------------------
modellf <- bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(25, 13), by=Year_fac) + 
                 te(Time_num_s, Julian_day_s, bs=c("cr", "cc"), k=c(5, 13)), control=list(trace=TRUE),
               data = Data, method="fREML", discrete=T, nthreads=8)

# Data prediction ---------------------------------------------------------

modellf<-readRDS("Temperature analysis/Models/modellf.Rds")



newdata_all <- WQ_pred(Full_data=Data, 
                       Julian_days = 1:365,
                       Years=round(min(Data$Year):max(Data$Year)))
#saveRDS(newdata_all, file="Temperature analysis/Prediction Data all.Rds")
newdata_all<-readRDS("Temperature analysis/Prediction Data all.Rds")

cl <- makeCluster(8) 
modellf_predictions_all<-predict(modellf, newdata=newdata_all, type="response", se.fit=FALSE, discrete=T, cluster=cl, newdata.guaranteed=TRUE) # Create predictions
#saveRDS(modellf_predictions_all, file="Temperature analysis/Model outputs and validations/modellf_predictions_all.Rds")
modellf_predictions_all<-readRDS("Temperature analysis/Model outputs and validations/modellf_predictions_all.Rds")

## Visualize all predictions
newdata_all<-newdata_all%>%
  mutate(Prediction=modellf_predictions_all,
         Date=as.Date(Julian_day, origin=as.Date(paste(Year, "01", "01", sep="-"))),
         Month=month(Date))

ggplot(data=filter(newdata_all, Location==590), aes(x=Date, y=Prediction))+
  geom_point(aes(color=Month))+
  geom_line()

newdata_all_sum<-newdata_all%>%
  lazy_dt()%>%
  group_by(Month, Year, Location, Latitude, Longitude)%>%
  summarise(Monthly_mean=mean(Prediction, na.rm=T), Monthly_sd=sd(Prediction, na.rm=T))%>%
  as_tibble()
#saveRDS(newdata_all_sum, file="Temperature analysis/Model outputs and validations/newdata_all_sum.Rds")
newdata_all_sum<-readRDS("Temperature analysis/Model outputs and validations/newdata_all_sum.Rds")

newdata_year<-readRDS("Temperature analysis/Prediction Data.Rds")
modellf_predictions<-predict(modellf, newdata=newdata_year, type="response", se.fit=TRUE, discrete=T, n.threads=8) # Create predictions
#saveRDS(modellf_predictions, file="Temperature analysis/Model outputs and validations/modellf_predictions.Rds")
# Predictions stored as "modellf_predictions.Rds"

modellf_predictions<-readRDS("Temperature analysis/model outputs and validations/modellf_predictions.Rds")

newdata<-newdata_year%>%
  mutate(Prediction=modellf_predictions$fit)%>%
  mutate(SE=modellf_predictions$se.fit,
         L95=Prediction-SE*1.96,
         U95=Prediction+SE*1.96)%>%
  mutate(Date=as.Date(Julian_day, origin=as.Date(paste(Year, "01", "01", sep="-")))) # Create Date variable from Julian Day and Year

# Year predictions --------------------------------------------------------

mygrid <- data.frame(
  name = c("Upper Sacramento River Ship Channel", "Cache Slough and Lindsey Slough", "Lower Sacramento River Ship Channel", "Liberty Island", "Suisun Marsh", "Middle Sacramento River", "Lower Cache Slough", "Steamboat and Miner Slough", "Upper Mokelumne River", "Lower Mokelumne River", "Georgiana Slough", "Sacramento River near Ryde", "Sacramento River near Rio Vista", "Grizzly Bay", "West Suisun Bay", "Mid Suisun Bay", "Honker Bay", "Confluence", "Lower Sacramento River", "San Joaquin River at Twitchell Island", "San Joaquin River at Prisoners Pt", "Disappointment Slough", "Lower San Joaquin River", "Franks Tract", "Holland Cut", "San Joaquin River near Stockton", "Mildred Island", "Middle River", "Old River", "Upper San Joaquin River", "Grant Line Canal and Old River", "Victoria Canal"),
  row = c(2, 2, 2, 2, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 7, 7, 8, 8, 8),
  col = c(7, 4, 6, 5, 2, 8, 6, 7, 9, 9, 8, 7, 6, 2, 1, 2, 3, 4, 5, 6, 8, 9, 5, 6, 7, 9, 8, 8, 7, 9, 8, 7),
  code = c(" 1", " 1", " 2", " 3", " 8", " 4", " 5", " 6", " 7", " 9", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "23", "24", "25", "26", "27", "28", "30", "29", "31"),
  stringsAsFactors = FALSE
)

Data_effort <- Data%>%
  st_drop_geometry()%>%
  group_by(SubRegion, Month, Year)%>%
  summarise(N=n(), .groups="drop")

newdata_year2<-newdata%>%
  select(-N)%>%
  mutate(Month=month(Date))%>%
  left_join(Data_effort, by=c("SubRegion", "Month", "Year"))%>% 
  filter(!is.na(N))

Data_year<-Data%>%
  filter(hour(Time)<14 & hour(Time)>10)%>%
  lazy_dt()%>%
  group_by(Year, Month, Season, SubRegion)%>%
  summarize(SD=sd(Temperature), Temperature=mean(Temperature))%>%
  ungroup()%>%
  as_tibble()

newdata_sum<-newdata_year2%>%
  mutate(Var=SE^2,
         Month=month(Date))%>%
  lazy_dt()%>%
  group_by(Year, Month, SubRegion)%>%
  summarise(Temperature=mean(Prediction), SE=sqrt(sum(Var)/(n()^2)))%>%
  ungroup()%>%
  as_tibble()%>%
  mutate(L95=Temperature-1.96*SE,
         U95=Temperature+1.96*SE)

# Plot by Season for 1 subregion
ggplot(filter(newdata_sum, SubRegion=="Confluence"))+
  geom_ribbon(aes(x=Year, ymin=L95, ymax=U95), fill="darkorchid4", alpha=0.5)+
  geom_line(aes(x=Year, y=Temperature))+
  geom_pointrange(data=filter(Data_year, SubRegion=="Confluence"), aes(x=Year, y=Temperature, ymin=Temperature-SD, ymax=Temperature+SD))+
  facet_grid(~Month)+
  theme_bw()+
  theme(panel.grid=element_blank())

# Plot by Subregion for every month
mapyear<-function(month){
  ggplot(filter(newdata_sum, Month==month))+
    geom_ribbon(aes(x=Year, ymin=L95, ymax=U95), fill="firebrick3", alpha=0.5)+
    geom_line(aes(x=Year, y=Temperature), color="firebrick3")+
    geom_pointrange(data=filter(Data_year, Month==month), aes(x=Year, y=Temperature, ymin=Temperature-SD, ymax=Temperature+SD), size=0.5, alpha=0.4)+
    facet_geo(~SubRegion, grid=mygrid, labeller=label_wrap_gen())+
    theme_bw()+
    theme(panel.grid=element_blank(), axis.text.x = element_text(angle=45, hjust=1))
}

walk(1:12, function(x) ggsave(plot=mapyear(x), filename=paste0("Temperature analysis/Figures/Year predictions month ", x, " f.png"), device=png(), width=15, height=12, units="in"))


# Rasterized predictions --------------------------------------------------

Delta<-st_read("Delta Subregions")%>%
  filter(SubRegion%in%unique(Data$SubRegion))%>% # Remove regions outside our domain of interest
  dplyr::select(SubRegion)

Data_effort <- Data%>%
  st_drop_geometry()%>%
  group_by(SubRegion, Month, Year)%>%
  summarise(N=n(), .groups="drop")

newdata_rast <- newdata%>%
  mutate(Month=month(Date))%>%
  left_join(newdata_all_sum%>%
              select(-Latitude, -Longitude), 
            by=c("Month", "Year", "Location"))%>%
  select(-N)%>%
  left_join(Data_effort, by=c("SubRegion", "Month", "Year"))%>% 
  mutate(across(c(Prediction, SE, L95, U95, Monthly_mean, Monthly_sd), ~if_else(is.na(N), NA_real_, .)))

# Create full rasterization of all predictions for interactive visualizations
rastered_preds<-Rasterize_all(newdata_rast, Prediction, region=Delta, cores=8)
# Same for SE
rastered_SE<-Rasterize_all(newdata_rast, SE, region=Delta, cores=8)
# Same for Monthly_mean
rastered_Monthly_mean<-Rasterize_all(newdata_rast, Monthly_mean, region=Delta, cores=8)
# Same for Monthly_sd
rastered_Monthly_sd<-Rasterize_all(newdata_rast, Monthly_sd, region=Delta, cores=8)

# Bind SE and predictions together
rastered_predsSE<-c(rastered_preds, rastered_SE, rastered_Monthly_mean, rastered_Monthly_sd)

saveRDS(rastered_predsSE, file="Shiny app/Rasterized modellf predictions.Rds")


# rasterize predictions for all dates-----------------------------------------------

newdata_all_rast <- newdata_all%>%
  select(-N)%>%
  left_join(Data_effort, by=c("SubRegion", "Month", "Year"))%>% 
  mutate(Prediction=if_else(is.na(N), NA_real_, Prediction))

rastered_preds_all<-Rasterize_all(newdata_all_rast, Prediction, region=Delta, cores=5)

# Model error by region ---------------------------------------------------

#modellf<-readRDS("Temperature analysis/Models/modellf.Rds")
#modellf_residuals <- modellf$residuals
#saveRDS(modellf_residuals, file="Temperature analysis/model outputs and validations/modellf_residuals.Rds")
modellf_residuals<-readRDS("Temperature analysis/model outputs and validations/modellf_residuals.Rds")

#modellf_fitted <- modellf$fitted.values
#saveRDS(modellf_fitted, file="Temperature analysis/model outputs and validations/modellf_fitted.Rds")
modellf_fitted<-readRDS("Temperature analysis/model outputs and validations/modellf_fitted.Rds")


Data_resid<-Data%>%
  mutate(Residuals = modellf_residuals)

Resid_sum<-Data_resid%>%
  lazy_dt()%>%
  group_by(Year, Month, SubRegion)%>%
  summarise(Resid=mean(Residuals), SD=sd(Residuals))%>%
  ungroup()%>%
  as_tibble()

p_resid<-ggplot(Resid_sum)+
  geom_tile(aes(x=Year, y=Month, fill=Resid))+
  scale_fill_gradient2(high = muted("red"),
                       low = muted("blue"),
                       breaks=seq(-3,5.5, by=0.5),
                       guide=guide_colorbar(barheight=40))+
  scale_x_continuous(breaks=unique(Resid_sum$Year), labels = if_else((unique(Resid_sum$Year)/2)%% 2 == 0, as.character(unique(Resid_sum$Year)), ""))+
  scale_y_continuous(breaks=unique(Resid_sum$Month), labels = if_else(unique(Resid_sum$Month)%% 2 == 0, as.character(unique(Resid_sum$Month)), ""))+
  facet_geo(~SubRegion, grid=mygrid, labeller=label_wrap_gen())+
  theme_bw()+
  theme(axis.text.x=element_text(angle=45, hjust=1), panel.grid=element_blank(), panel.background = element_rect(fill="black"))

ggsave(plot=p_resid, filename="Temperature analysis/Figures/modellf residuals.png", device=png(), width=20, height=12, units="in")


# Plot sampling effort ----------------------------------------------------

p_effort<-ggplot(Data_effort)+
  geom_tile(aes(x=Year, y=Month, fill=N))+
  scale_fill_viridis_c(breaks=seq(0,140, by=10),
                       guide=guide_colorbar(barheight=40))+
  scale_x_continuous(breaks=unique(Data_effort$Year), labels = if_else((unique(Data_effort$Year)/2)%% 2 == 0, as.character(unique(Data_effort$Year)), ""))+
  scale_y_continuous(breaks=unique(Data_effort$Month), labels = if_else(unique(Data_effort$Month)%% 2 == 0, as.character(unique(Data_effort$Month)), ""))+
  facet_geo(~SubRegion, grid=mygrid, labeller=label_wrap_gen())+
  theme_bw()+
  theme(axis.text.x=element_text(angle=45, hjust=1), panel.grid=element_blank())

ggsave(plot=p_effort, filename="Temperature analysis/Figures/Effort.png", device=png(), width=20, height=12, units="in")


# Stratified cross-validation ---------------------------------------------
set.seed(100)
Data_split<-Data%>%
  mutate(Resid=modellf_residuals,
         Fitted=modellf_fitted)%>%
  group_by(SubRegion, Year, Season, Group)%>%
  mutate(Fold=sample(1:10, 1, replace=T))%>%
  ungroup()
set.seed(NULL)

#saveRDS(Data_split, file="Temperature analysis/Split data for cross validation.Rds")

# Saved as "Split data for cross validation.Rds"

CVf_fit_1=list()
#~2 hours per model run
for(i in 1:10){
  out<-bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(25, 13), by=Year_fac) + 
             te(Time_num_s, Julian_day_s, bs=c("cr", "cc"), k=c(5, 13)),
           data = filter(Data_split, Group==1 & Fold!=i)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)
  saveRDS(out, file=paste0("Temperature analysis/Models/CV/CVf_model_1_", i, ".Rds"))
  CVf_fit_1[[i]]<-predict(out, newdata=filter(Data_split, Group==1 & Fold==i), type="response", se.fit=FALSE, discrete=T, n.threads=8)
  rm(out)
  gc()
  message(paste0("Finished run ", i, "/10")) 
}

saveRDS(CVf_fit_1, file="Temperature analysis/model outputs and validations/Group 1 CV predictions f.Rds")

CVf_fit_2=list()
for(i in 1:10){
  out<-bam(Temperature ~ Year_fac + te(Longitude_s, Latitude_s, Julian_day_s, d=c(2,1), bs=c("cr", "cc"), k=c(25, 13), by=Year_fac) + 
             te(Time_num_s, Julian_day_s, bs=c("cr", "cc"), k=c(5, 13)),
           data = filter(Data_split, Group==2 & Fold!=i)%>%mutate(Year_fac=droplevels(Year_fac)), method="fREML", discrete=T, nthreads=8)
  saveRDS(out, file=paste0("Temperature analysis/Models/CV/CVf_model_2_", i, ".Rds"))
  CVf_fit_2[[i]]<-predict(out, newdata=filter(Data_split, Group==2 & Fold==i), type="response", se.fit=FALSE, discrete=T, n.threads=8)
  rm(out)
  gc()
  message(paste0("Finished run ", i, "/10"))  
}

saveRDS(CVf_fit_2, file="Temperature analysis/model outputs and validations/Group 2 CV predictions f.Rds")

Data_split_CV_f<-map2_dfr(rep(c(1,2), each=10), rep(1:10,2), ~CV_bind(group=.x, fold=.y))%>%
  mutate(Resid_CV=Fitted_CV-Temperature,
         Fitted_resid=Fitted_CV-Fitted)

# EMP (first year-round survey) started in 1974 so restricting analysis to those years
Resid_CV_sum_f<-Data_split_CV_f%>%
  filter(Year>=1974)%>%
  lazy_dt()%>%
  group_by(Year, Month, SubRegion)%>%
  summarise(SD=sd(Resid_CV), Resid_CV=mean(Resid_CV), Fitted_resid=mean(Fitted_resid))%>%
  ungroup()%>%
  as_tibble()

RMSE <- function(m, o){
  sqrt(mean((m - o)^2))
}

CV_sum<-Data_split_CV_f%>%
  st_drop_geometry()%>%
  group_by(Group, Fold)%>%
  summarise(RMSE=sqrt(mean(Resid_CV^2)), 
            r=cor(Fitted_CV, Temperature, method="pearson"), .groups="drop")

# First plot deviation of predicted values from true values
p_resid_CV<-ggplot(Resid_CV_sum_f)+
  geom_tile(aes(x=Year, y=Month, fill=Resid_CV))+
  scale_fill_gradient2(high = muted("red"),
                       low = muted("blue"),
                       breaks=-9:7,
                       guide=guide_colorbar(barheight=40))+
  scale_x_continuous(breaks=unique(Resid_CV_sum_f$Year), labels = if_else((unique(Resid_CV_sum_f$Year)/2)%% 2 == 0, as.character(unique(Resid_CV_sum_f$Year)), ""))+
  scale_y_continuous(breaks=unique(Resid_CV_sum_f$Month), labels = if_else(unique(Resid_CV_sum_f$Month)%% 2 == 0, as.character(unique(Resid_CV_sum_f$Month)), ""))+
  facet_geo(~SubRegion, grid=mygrid, labeller=label_wrap_gen())+
  theme_bw()+
  theme(axis.text.x=element_text(angle=45, hjust=1), panel.grid=element_blank(), panel.background = element_rect(fill="black"))
p_resid_CV
ggsave(plot=p_resid_CV, filename="Temperature analysis/Figures/CV Residuals f.png", device=png(), width=20, height=12, units="in")


# Next plot deviation of predicted values from fitted values from full model
p_resid_CV2<-ggplot(Resid_CV_sum_f)+
  geom_tile(aes(x=Year, y=Month, fill=Fitted_resid))+
  scale_fill_gradient2(high = muted("red"),
                       low = muted("blue"))+
  scale_x_continuous(breaks=unique(Resid_CV_sum_f$Year), labels = if_else((unique(Resid_CV_sum_f$Year)/2)%% 2 == 0, as.character(unique(Resid_CV_sum_f$Year)), ""))+
  scale_y_continuous(breaks=unique(Resid_CV_sum_f$Month), labels = if_else(unique(Resid_CV_sum_f$Month)%% 2 == 0, as.character(unique(Resid_CV_sum_f$Month)), ""))+
  facet_geo(~SubRegion, grid=mygrid, labeller=label_wrap_gen())+
  theme_bw()+
  theme(axis.text.x=element_text(angle=45, hjust=1), panel.grid=element_blank(), panel.background = element_rect(fill="black"))
ggsave(plot=p_resid_CV2, filename="Temperature analysis/Figures/CV Residuals2 f.png", device=png(), width=20, height=12, units="in")


# Test autocorrelation ----------------------------------------------------

auto<-Data%>%
  mutate(Resid=modellc4_residuals)%>%
  filter(Source!="EDSM" & !str_detect(Station, "EZ"))%>% # Remove EDSM and EZ stations because they're not fixed
  mutate(Station=paste(Source, Station))%>%
  group_by(Station)%>%
  mutate(N=n())%>%
  filter(N>10)%>%
  summarise(ACF=list(pacf(Resid, plot=F)), N=n(), ci=qnorm((1 + 0.95)/2)/sqrt(n()), .groups="drop")%>% # ci formula from https://stackoverflow.com/questions/14266333/extract-confidence-interval-values-from-acf-correlogram
  rowwise()%>%
  mutate(lag=list(ACF$lag), acf=list(ACF$acf))%>%
  unnest(cols=c(lag, acf))%>%
  arrange(-N)%>%
  mutate(Station=factor(Station, levels=unique(Station)))

length(which(abs(auto$acf)>abs(auto$ci)))/nrow(auto)

# Only 6% exceed the CI, very close to the 5% you would expect with our chosen confidence level of 0.95 so I'm taking this as good evidence of no autocorrelation

length(which(abs(filter(auto, lag==1)$acf)>abs(filter(auto, lag==1)$ci)))/nrow(filter(auto, lag==1))
# Around 30% exceed the CI at a lag of 1
# Limitations: Not all surveys sample monthly, so lags aren't constant

ggplot(filter(auto, lag==1))+
  geom_point(aes(x=Station, y=abs(acf)), fill="black", shape=21)+
  geom_point(data=filter(auto, lag==1 & abs(acf)>abs(ci)), aes(x=Station, y=abs(acf)), fill="red", shape=21)+
  geom_point(aes(x=Station, y=abs(ci)), fill="white", shape=21)+
  geom_segment(aes(x=Station, y=abs(acf), xend=Station, yend=abs(ci)), linetype=2)+
  geom_segment(data=filter(auto, lag==1 & abs(acf)>abs(ci)), aes(x=Station, y=abs(acf), xend=Station, yend=abs(ci)), color="red")+
  theme_bw()+
  theme(panel.grid=element_blank(), axis.text.x=element_text(angle=45, hjust=1))

# Using a continuous method
require(gstat)
require(sp)
require(spacetime)
Vario_data <- data.frame(Residuals=modellc4_residuals/sd(Data$Temperature), Longitude=Data$Longitude, Latitude=Data$Latitude)
coordinates(Vario_data)<-c("Longitude", "Latitude")
vario<-variogram(Residuals~1, Vario_data)
plot(vario)

sp <- SpatialPoints(coords=data.frame(Longitude=Data$Longitude, Latitude=Data$Latitude))
sp2<-STIDF(sp, time=Data$Date, data=data.frame(Residuals=modellc4_residuals/sd(Data$Temperature)))
vario2<-variogramST(Residuals~1, data=sp2, tunit="weeks", cores=3)
save(vario, vario2, file="Variograms.Rds")

ggplot(vario2, aes(x=timelag, y=gamma, color=avgDist, group=avgDist))+
  geom_line()+
  geom_point()
