mapplot<-function(data, type="paper", point=tibble(Latitude=37.999664, Longitude=-121.317443), yolo=NULL){
  
  require(dplyr)
  require(sf)
  require(ggplot2)
  require(maps)
  require(ggspatial)
  require(patchwork)
  
  SubRegions<-deltamapr::R_EDSM_Subregions_Mahardja%>%
    filter(SubRegion%in%unique(data$SubRegion))
  
  base<-deltamapr::WW_Delta%>%
    st_transform(crs=st_crs(SubRegions))%>%
    st_crop(SubRegions)
  
  Data<-data%>%
    group_by(Station, Latitude, Longitude)%>%
    summarise(N=n(), .groups="drop")%>%
    st_as_sf(coords=c("Longitude", "Latitude"), crs=4326)%>%
    st_transform(crs=st_crs(SubRegions))
  
  
  # Map for a presentation ------------------------------
  if(type=="Presentation"){
    p<-ggplot()+
      geom_sf(data=base, fill="slategray1", color="slategray2")+
      geom_sf(data=Data, aes(color=N))+
      ylab("")+
      xlab("")+
      #coord_sf(datum=st_crs(SubRegions))+
      scale_color_viridis_c(guide=guide_colorbar(barwidth=7.5, barheight=0.8))+
      theme_bw()+
      theme(legend.position = c(0.25, 0.8), legend.background=element_rect(color="black"), legend.direction = "horizontal", plot.margin = margin(0,0,0,0))+
      annotation_scale(location = "bl") +
      annotation_north_arrow(location = "bl", pad_y=unit(0.05, "npc"), which_north = "true")
    return(p)
  }
  
  
  states <- st_as_sf(map("state", plot = FALSE, fill = TRUE))%>%
    st_transform(crs=st_crs(SubRegions))
  california<-filter(states, ID=="california")
  
  base2<-base%>%
    st_make_valid()%>%
    st_crop(Data)
  
  station_lims<-st_bbox(Data)
  
  labels<-tibble(label=c("Suisun Bay", "Suisun Marsh", "Confluence", "Cache Slough", "Sacramento River", 
                         "Sacramento\nShip Channel", "San Joaquin River", "Cosumnes River", "Mokelumne\nRiver", "Yolo Bypass"), 
                 Y=c(4212000, 4226700, 4211490, 4232164, 4262276, 
                     4264345, 4183000,4247000,4225000, 4262058), 
                 X=c(583318, 590000, 597000, 615970, 625568, 
                     623600,649500,645000,648500, 620000),
                 label_Y=c(4208500, 4240000, 4200000, 4228686, 4262276, 
                           4268058, 4180000, 4255000,4220000, 4262058), 
                 label_X=c(585000, 590000, 610000, 607572, 640000, 
                           640000, 642000, 642000, 647000, 608000))
  
  #plot(select(base, geometry),reset=F, col="slategray1", border="slategray2")
  #plot(select(SubRegions, geometry), add=T, lwd=2)
  #points(as_tibble(st_coordinates(Data)), col="black", pch=16)
  #Letter_locs<-locator()
  
  Letters<-tibble(Label=c(letters, paste0("a", letters)[1:6]), 
                  SubRegion=c("Upper Sacramento River Ship Channel", "Middle Sacramento River",
                              "Lower Sacramento River Ship Channel", "Steamboat and Miner Slough",
                              "Cache Slough and Lindsey Slough", "Liberty Island",
                              "Lower Cache Slough", "Sacramento River near Ryde",
                              "Georgiana Slough", "Upper Mokelumne River",
                              "Suisun Marsh", "West Suisun Bay",
                              "Grizzly Bay", "Mid Suisun Bay",
                              "Honker Bay", "Confluence",
                              "Lower Sacramento River", "Sacramento River near Rio Vista",
                              "San Joaquin River at Twitchell Island", "San Joaquin River at Prisoners Pt",
                              "Lower Mokelumne River", "Disappointment Slough",
                              "Lower San Joaquin River", "Franks Tract", 
                              "Holland Cut", "Mildred Island",
                              "San Joaquin River near Stockton", "Old River",
                              "Middle River", "Grant Line Canal and Old River",
                              "Victoria Canal", "Upper San Joaquin River"),
                  X=c(627233.1, 629416.7, 620376.8, 622167.3, 606969.7, 613040.0, 616315.3, 
                      618236.9, 624700.2, 633347.1, 594610.7, 576661.9, 586793.6, 585920.2, 
                      594916.4, 600593.7, 604960.8, 613258.3, 618586.2, 627407.8, 628718.0, 
                      639854.1, 614393.8, 622254.6, 625398.9, 631949.6, 640334.5, 626621.7, 
                      632735.7, 640683.9, 623914.1, 647234.5),
                  Y=c(4271603, 4257104, 4249768, 4248719, 4246711, 4245837, 4228543, 
                      4223128, 4224002, 4232212, 4232648, 4214307, 4219984, 4211599, 
                      4214831, 4214569, 4215180, 4215180, 4218848, 4214743, 4222167, 
                      4219547, 4210289, 4215005, 4212298, 4204961, 4204350, 4203127, 
                      4202253, 4200244, 4193432, 4197886))%>%
    mutate(Label2=paste(Label, ":"),
           Label2=factor(Label2, levels=Label2))
  #paste(Letters$Label, Letters$SubRegion, sep=" - ", collapse=", ")
  
  if(!is.null(point)){
    point<-point%>%
      st_as_sf(coords=c("Longitude", "Latitude"), crs=4326)%>%
      st_transform(crs=st_crs(SubRegions))
  }
  
  if(!is.null(yolo)){
    yolo<-yolo%>%
      st_transform(crs=st_crs(SubRegions))%>%
      st_union()%>%
      st_crop(SubRegions)
  }else{
    labels<-filter(labels, label!="Yolo Bypass")
  }
  
  pout<-ggplot(states)+
    geom_sf(color="slategray1", fill="gray70")+
    geom_sf(data=base2, color="slategray1", fill="slategray1")+
    geom_rect(xmin = station_lims["xmin"]-0.2, xmax = station_lims["xmax"]+0.2, ymin = station_lims["ymin"]-0.2, ymax = station_lims["ymax"]+0.2, 
              fill = NA, colour = "black", size = 1)+
    coord_sf(xlim=c(st_bbox(california)["xmin"], st_bbox(california)["xmax"]), ylim=c(st_bbox(california)["ymin"], st_bbox(california)["ymax"]))+
    theme_bw()+
    theme(panel.background = element_rect(fill = "slategray1"), axis.text.x=element_text(angle=45, hjust=1))
  #pout
  
  p<-ggplot()+
    {if(!is.null(yolo)){
      geom_sf(data=yolo, color=NA, fill="gray80", alpha=0.5)
    }}+
    geom_sf(data=base, fill="slategray1", color="slategray2")+
    geom_sf(data=SubRegions, alpha=0.1)+
    geom_segment(data=labels, aes(x=label_X, y=label_Y, xend=X, yend=Y), size=1)+
    geom_label(data=labels, aes(label=label, x=label_X, y=label_Y))+
    geom_sf(data=Data, aes(color=N))+
    geom_segment(data=tibble(x=580000, y=4205000, xend=575000, yend=4205000), aes(x=x, y=y, xend=xend, yend=yend), arrow=arrow(length = unit(0.03, "npc")), size=1)+
    geom_label(data=tibble(x=590000, y=4205000, label="to San Francisco Bay"), aes(x=x, y=y, label=label))+
    geom_text(data=Letters, aes(x=X, y=Y, label=Label))+
    {if(!is.null(point)){
      geom_sf(data=point, color="firebrick3", shape=17, size=2)
    }}+
    ylab("")+
    xlab("")+
    #coord_sf(datum=st_crs(SubRegions))+
    scale_color_viridis_c(guide=guide_colorbar(barwidth=7.5, barheight=0.8, title.position="top", title.hjust=0.5), 
                          name="Sample size", breaks=c(1, 100, 200, 300, 400, 500))+
    theme_bw()+
    theme(legend.position = c(0.2, 0.2), legend.background=element_rect(color="black"), legend.direction = "horizontal", plot.margin = margin(0,0,0,0))+
    annotation_scale(location = "bl") +
    annotation_north_arrow(location = "bl", pad_y=unit(0.05, "npc"), which_north = "true")+
    annotation_custom(
      grob = ggplotGrob(pout),
      xmin = -Inf,
      xmax = 599971,
      ymin = 4242767,
      ymax = Inf
    )
  
  text_wrap<-function(label, width){x <- strwrap(label, width = width, simplify = FALSE)
  vapply(x, paste, character(1), collapse = "\n")}
  
  p_letters<-ggplot(Letters, aes(x=1, y=Label2, label=text_wrap(SubRegion, 20)))+
    geom_text(hjust=0, size=3, lineheight=0.8)+
    scale_x_continuous(expand=expansion(0,0), limits=c(1, 1.15))+
    scale_y_discrete(limits = rev)+
    theme_bw()+
    theme(panel.grid=element_blank(), axis.ticks.x=element_blank(), axis.line = element_blank(), axis.text.x=element_blank(), 
          axis.title.x=element_blank(), axis.title.y=element_blank(), plot.background = element_blank(), panel.border = element_blank(),
          text=element_text(size=12), plot.margin = margin(0,0,0,1), axis.ticks = element_blank())
  
  p_final<-p+p_letters+plot_layout(widths=c(0.83, 0.17))
  return(p_final)
}


# Climate change analyses ----------------------------------------------------


Data_CC4<-readRDS("Temperature analysis/Data_CC4.Rds")

p_CC4_final<-mapplot(Data_CC4, point=NULL)

ggsave("C:/Users/sbashevkin/deltacouncil/Science Extranet - Discrete water quality synthesis/Temperature change/Figures/Figure 1 map.tiff", plot=p_CC4_final, device="tiff", dpi=400, width=8, height=8, units = "in")


# Map for presentation

p_CC4_presentation<-mapplot(Data_CC4, "Presentation", point=NULL)

ggsave("C:/Users/sbashevkin/deltacouncil/Science Extranet - Discrete water quality synthesis/Temperature change/Figures/BDSC Map.png", plot=p_CC4_presentation, device="png", width=6, height=6, units = "in")


# Inflow analyses ---------------------------------------------------------

yolo<-sf::st_read("Yolo Bypass Extent")

Data_D2<-readRDS("Temperature analysis/Data_D2.Rds")

p_D2_final<-mapplot(Data_D2, yolo=yolo)

ggsave("C:/Users/sbashevkin/deltacouncil/Science Extranet - Discrete water quality synthesis/Delta inflow temperature/Figures/Figure 2 map.tiff", plot=p_D2_final, device="tiff", width=8, height=8, units = "in", dpi=400)

