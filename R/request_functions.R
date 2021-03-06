# Functions that gather or check information using API requests

get_accepted_name = function(name_in) {
  # lookup name in POWO
  powo_results <- search_name_powo(name_in)

  # remove anything that wasn't the name we wanted
  if (any(! is.na(powo_results$IPNI_ID))) {
    powo_results <- filter(powo_results, name == name_in)

    powo_results <- unite(powo_results, fullname, name, author, sep=" ", remove=FALSE)
    # want to take an accepted name if it's there
    powo_results <- arrange(powo_results, desc(accepted))
    
    powo_results <- powo_results[1,]
  }
  
  # add on the name searched for
  powo_results$name_searched <- name_in
  
  powo_results <- rename(powo_results, name_in=name)

  return(powo_results)
}

search_name_powo = function(name_in) {

  powo_results <- tibble(
    IPNI_ID=NA_character_,
    name=NA_character_,
    author=NA_character_,
    accepted=NA
  )

  # use name full name to search API  
  full_url =  paste("http://plantsoftheworldonline.org/api/1/search?q=name:", name_in, sep = "")
  
  # encode
  full_url = utils::URLencode(full_url)
  
  # get raw json data
  raw_data <- readLines(full_url, warn = "F", encoding = "UTF-8")
  
  # organise
  rd = fromJSON(raw_data)
  
  if (length(rd$results) > 0) {

    # make data frame
    results = rd$results
    
    # get IPNI ID
    results = mutate(results, IPNI_ID=str_extract(url, "(?<=names\\:)[\\d\\-]+$"))

    # only include these fields - you don't want synonym of
    powo_results = select(results, colnames(powo_results))
  }
  
  return(powo_results)
  
}

lookup_powo <- function(ID, distribution=FALSE) {
  lookup_url <- paste("http://plantsoftheworldonline.org/api/2/taxon/urn:lsid:ipni.org:names:", ID, sep="")
  if (distribution) {
    response <- httr::GET(lookup_url, query=list(fields="distribution"))
  } else {
    response <- httr::GET(lookup_url)
  }

  if (! httr::http_error(response)) {
    return(fromJSON(content(response, as="text")))
  }
  return(NULL)  
}

get_native_range = function(ID){
  results = tibble(
      LEVEL3_COD=NA_character_,
      featureId=NA_character_,
      tdwgLevel=NA_integer_,
      establishment=NA_character_,
      LEVEL3_NAM=NA_character_,
      POWO_ID=NA_character_
  )

  returned_data <- lookup_powo(ID, distribution=TRUE)
  distribution <- returned_data$distribution$natives
    
  if (! is.null(distribution)) {
    results = mutate(distribution, POWO_ID=ID)
    results = rename(results, LEVEL3_NAM=name, LEVEL3_COD=tdwgCode)
    results = mutate(results, LEVEL3_NAM=recode(LEVEL3_NAM, "á"="a"))
  }
  
  return(results)
}

check_if_native = function(points, native_range, range_polygons){
  
  if (is.na(points$BINOMIAL[1])) {
    native_points <- mutate(points, native_range=NA_character_)
    return(native_points)
  }

  # TODO: maybe replace/add option for raster solution if more points provided
  # prepare the point data as spatial
  point_sf <- st_as_sf(points, 
                       coords=c("DEC_LONG", "DEC_LAT"),
                       crs=st_crs(range_polygons), 
                       remove=FALSE)
  # get shapes of native range
  native_tdwg <- filter(range_polygons, LEVEL3_COD %in% native_range$LEVEL3_COD)
  native_tdwg <- select(native_tdwg, LEVEL3_COD)
  # clip points to native range with a spatial join
  native_points <- st_join(point_sf, native_tdwg)
  native_points <- rename(native_points, native_range=LEVEL3_COD)
  # convert back to normal data frame from sf
  native_points <- as_tibble(native_points)
  native_points <- select(native_points, -geometry)
  
  native_points
}

search_name_gbif = function (full_name) {
  
  options = data.frame(
    usageKey = NA_integer_,
    acceptedUsageKey = NA_character_,
    scientificName = NA_character_,
    rank = NA_character_,
    status = NA_character_,
    confidence = NA_integer_,
    family = NA_character_,
    acceptedSpecies = NA_character_
  )
  
  gbif_results = name_backbone(
    name = full_name,
    rank = 'species',
    kingdom = 'Plantae',
    strict = FALSE,
    verbose = TRUE #change to TRUE to get more options
  )
  
  # bind together in case there are missing data
  merged = bind_rows(gbif_results$alternatives, gbif_results$data)
  
  if (nrow(merged) > 1 | merged$matchType[1] != "HIGHERRANK") {
    # change col names
    merged = rename(merged, acceptedSpecies=species)
    
    if (!"acceptedUsageKey" %in% colnames(merged)) {
      merged$acceptedUsageKey = NA_character_
    }
    
    # subset the data with the fields you want
    options = select(merged, colnames(options))
  
    # arrange table in descending order to show best guess at top of table
    options = arrange(options, desc(confidence))
  }
  
  options
}

get_gbif_key <- function(species_name) {
  bad_result_types <- c(
    "PROPARTE_SYNONYM",
    "DOUBTFUL",
    "HETEROTYPIC_SYNONYM",
    "HOMOTYPIC_SYNONYM",
    "MISAPPLIED",
    "SYNONYM"
  )

  warning <- NA_character_
  gbif_key <- NA_integer_
  
  gbif_matches <- search_name_gbif(species_name)

  if (is.na(gbif_matches$usageKey[1])) {
    warning <- "No name match in GBIF"
  }

  if (gbif_matches$status[1] %in% bad_result_types) {
    # Is this really something bad? As long as it's accepted in POWO?
    warning <- "Best name match against GBIF is not treated by GBIF as accepted"
  }

  if (is.na(warning)) {
    gbif_key <- gbif_matches$usageKey[1]
  }
 
  tibble(gbif_key=gbif_key,
         warning=warning)
}

get_gbif_points = function(key, gbif_limit) {
  result_name_map <- c(BasisOfRec="basisOfRecord",
                       DEC_LAT="decimalLatitude",
                       DEC_LONG="decimalLongitude",
                       EVENT_YEAR="year",
                       BINOMIAL="scientificName",
                       CATALOG_NO="catalogNumber")

  results = tibble(
    basisOfRecord = NA_character_,
    scientificName = NA_character_,
    decimalLatitude = -999,
    decimalLongitude = -999,
    year = -999L,
    catalogNumber = NA_character_,
    SPATIALREF = "WGS84",
    PRESENCE = "1",
    ORIGIN = "1",
    SEASONAL = "1",
    DATA_SENS = "No",
    SOURCE = NA_character_,
    YEAR = NA_character_,
    COMPILER = NA_character_,
    CITATION = NA_character_,
    recordedBy = NA_character_,
    recordNumber = NA_character_,
    issues = NA_character_,
    datasetKey = NA_character_
  )

  if (key != "" & ! is.na(key)) {
    gbif_results <- occ_data(
      taxonKey = key,
      hasGeospatialIssue = FALSE,
      hasCoordinate = TRUE,
      limit = gbif_limit
    )

    results_count <- gbif_results$meta$count
  } else {
    results_count <- 0
  }

  if (results_count > 0){
    gbif_points <- gbif_results$data
  } else {
    gbif_points <- results
  }
  
  if (nrow(gbif_points) > 0) {
       
    columns_to_add = setdiff(colnames(results), colnames(gbif_points))
    default_data = as.list(results)
    gbif_points = tibble::add_column(gbif_points, !!! default_data[columns_to_add])
        
    gbif_points$YEAR = format(Sys.Date(), "%Y")
    gbif_points$SOURCE = paste0("https://www.gbif.org/dataset/", gbif_points$datasetKey, sep = "")
    
    # reformat to iucn standard
    gbif_points = mutate(gbif_points,
                          basisOfRecord=recode(basisOfRecord,
                            "FOSSIL_SPECIMEN"="FossilSpecimen",
                            "HUMAN_OBSERVATION"="HumanObservation",
                            "LITERATURE"="",
                            "LIVING_SPECIMEN"="LivingSpecimen",
                            "MACHINE_OBSERVATION"="MachineObservation",
                            "OBSERVATION"="",
                            "PRESERVED_SPECIMEN"="PreservedSpecimen",
                            "UNKNOWN"="Unknown"
                          ))
    
    results = select(gbif_points, colnames(results))
  }
  
  results <- rename(results, !!! result_name_map)
  return(results)
}

get_random_powo = function(){
  search_url <- "http://plantsoftheworldonline.org/api/2/search"

  # make request for list of families and parse response
  family_response <- GET(search_url, query=list(f="accepted_names,family_f", page.size=480))
  family_content <- content(family_response, as="text")
  family_content <- fromJSON(family_content)
  family_results <- family_content$results

  # get random family
  random_family = family_results[sample(nrow(family_results), 1), ]$family
  
  # now get list of accepted genera from the random family
  genera_response <- GET(search_url, query=list(f="accepted_names,genus_f", page.size=480, q=random_family))
  genera_content <- content(genera_response, as="text")
  genera_results <- fromJSON(genera_content)

  # get a random genus number
  random_genus_number = sample(genera_results$totalResults, 1)
  returned_genera = nrow(genera_results$results)
  cursor = genera_results$cursor
  
  while (returned_genera < random_genus_number){
    genera_response <- GET(search_url, query=list(f="accepted_names,genus_f", page.size=480, q=random_family, cursor=cursor))
  
    genera_content <- content(genera_response, as="text")
    genera_results <- fromJSON(genera_content)
    returned_genera <- returned_genera + nrow(genera_results$results)
    cursor <- genera_results$cursor
  }
  
  # we're only keeping the latest results from POWO, so need to change the random genus number to match
  random_genus_number <- mod(random_genus_number, 480)
  
  # return random genus
  random_genus = genera_results$results[random_genus_number, ]$name
  
  #### now final step to get random species from genus - repeat method above
 
  # now get list of species from the random genus
  species_response <- GET(search_url, query=list(f="accepted_names,species_f", page.size=480, q=random_genus))
  species_content <- content(species_response, as="text")
  species_results <- fromJSON(species_content)
  
  # get species number
  random_species_number = sample(species_results$totalResults, 1)
  returned_species = nrow(species_results$results)
  cursor = species_results$cursor
  
  while (returned_species < random_species_number){
    
    species_response <- GET(search_url, query=list(f="accepted_names,genus_f", page.size=480, q=random_family, cursor=cursor))
  
    species_content <- content(species_response, as="text")
    species_results <- fromJSON(species_content)
    returned_species <- returned_genera + nrow(species_results$results)
    cursor <- species_results$cursor
  }
  
  # we're only keeping the latest results from POWO, so need to change the random species number to match
  random_species_number <- mod(random_species_number, 480)
  
  random_species = species_results$results[random_species_number, ]$name 
  
}
