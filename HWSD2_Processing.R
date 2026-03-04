setwd('D:/ArcGIS/HWSD2') # set current working directory
rm(list = ls()) # clear the environment
cat("\014") # clear the console

if (!require(pacman)) {install.packages('pacman')}



# HWSD2属性表数据导出 ------------------------------------------------------------------

pacman::p_load(openxlsx, tidyverse, RODBC)

# 读入data文件夹下的HWSD2数据库
mdb_path <- 'data/HWSD2.mdb'

# 创建输出目录
out_dir <- 'HWSD2mdbExtract'
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

# 导出所有数据表
conn_str <- paste0("Driver={Microsoft Access Driver (*.mdb, *.accdb)};DBQ=", mdb_path)
conn <- odbcDriverConnect(conn_str) # 连接到HWSD2数据库
# 获取数据库中所有表的名称
tables <- sqlTables(conn, tableType = "TABLE")
table_names <- tables$TABLE_NAME
# 循环读取每个表并保存为xlsx文件
for (table_name in table_names) {
   df <- sqlFetch(conn, table_name)
   safe_name <- gsub('[[:punct:]]', '_', table_name)
   output_file <- file.path(out_dir, paste0(safe_name, ".xlsx"))
   write.xlsx(df, output_file, rowNames = FALSE)
   cat(paste0("已保存: ", output_file, "\n\n"))
}
odbcClose(conn)

# 加工土层数据并导出
# 提取并保存所有土壤属性数据
export_layers_from_mdb <- function(mdb_path, output_excel) {
   conn_str <- paste0("Driver={Microsoft Access Driver (*.mdb, *.accdb)};DBQ=", mdb_path)
   conn <- odbcDriverConnect(conn_str)
   df <- sqlQuery(conn, "SELECT * FROM HWSD2_LAYERS", stringsAsFactors = FALSE)
   odbcClose(conn)
   wb <- createWorkbook()
   layer_groups <- split(df, df$LAYER) # 每个土层数据单独存到工作表中
   for (layer_type in names(layer_groups)) {
      sub_df <- layer_groups[[layer_type]]
      sheet_name <- as.character(layer_type)
      addWorksheet(wb, sheet_name)
      writeData(wb, sheet = sheet_name, x = sub_df, rowNames = FALSE)}
   saveWorkbook(wb, output_excel, overwrite = TRUE)
   cat(paste("处理完成！已输出：", output_excel, "\n"))
   return(invisible(TRUE))}
main <- function() {
   mdb_path <- mdb_path
   output_excel <- file.path(out_dir, 'HWSD2_layers_sep.xlsx') # 设置导出文件名
   export_layers_from_mdb(mdb_path, output_excel)}
main()
# 提取并保存各表 SEQUENCE = 1 的数据（即最主要的土壤类型）
filter_sequence_one <- function(excel_path, output_excel) {
   sheet_names <- getSheetNames(excel_path)
   wb <- createWorkbook()
   for (sheet_name in sheet_names) {
      df <- read.xlsx(excel_path, sheet = sheet_name)
      df_filtered <- df[df$SEQUENCE == 1, ]
      addWorksheet(wb, sheet_name)
      writeData(wb, sheet = sheet_name, x = df_filtered, rowNames = FALSE)}
   saveWorkbook(wb, output_excel, overwrite = TRUE)
   cat(paste("筛选完成！已输出：", output_excel, "\n"))
   return(invisible(TRUE))}
filter_sequence_one(
   file.path(out_dir, 'HWSD2_layers_sep.xlsx'),
   file.path(out_dir, 'HWSD2_layers_sep_filtered.xlsx')) # 设置导出文件名



# 生成HWSD2土壤单属性栅格（并行运算） ---------------------------------------------------------------
# 利用 SEQUENCE = 1 的数据（即最主要的土壤类型）

pacman::p_load(openxlsx, tidyverse, terra, doParallel)

# 创建输出目录
out_dir <- 'Attributes'
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)


## 数值型变量栅格 -----------------------------------------------------------------
# 并行处理
start1 <- Sys.time()
cl <- makeCluster(detectCores() - 2)
registerDoParallel(cl)
results <- foreach(layer = paste0("D", 1:7), .combine = c) %:% # 土层D1-D7
   foreach(field = c( # 数值型变量
      'COARSE', 'SAND', 'SILT', 'CLAY',
      'BULK', 'REF_BULK', 'ORG_CARBON', 'PH_WATER',
      'TOTAL_N', 'CN_RATIO', 'CEC_SOIL', 'CEC_CLAY',
      'CEC_EFF', 'TEB', 'BSAT', 'ALUM_SAT', 'ESP',
      'TCARBON_EQ', 'GYPSUM', 'ELEC_COND'), .combine = c) %dopar%
   {# 在每个节点内加载包和读取数据
      library(terra)
      library(openxlsx)
      # 利用 SEQUENCE = 1 的数据（即最主要的土壤类型）
      soil_data <- read.xlsx("HWSD2mdbExtract/HWSD2_layers_sep_filtered.xlsx", sheet = layer)
      soil_raster <- rast("data/HWSD2.bil") # 读取HWSD2土壤栅格数据
      soil_raster_field <- classify(
         soil_raster, rcl = cbind(as.numeric(soil_data$HWSD2_SMU_ID), soil_data[[field]]), others = NA)
      soil_raster_field[soil_raster_field < 0] <- NA # 将负值设为NA
      names(soil_raster_field) <- paste0(field, "_", layer)
      out_path <- file.path(out_dir, sprintf('%s_%s.tif', field, layer))
      writeRaster(soil_raster_field, out_path, overwrite = TRUE)
      rm(soil_raster, soil_raster_field)
      gc()
      paste(field, layer, "完成")}
stopCluster(cl)
end1 <- Sys.time()
end1 - start1 # ~ 10 h

# 并行处理
start2 <- Sys.time()
cl <- makeCluster(detectCores() - 2)
registerDoParallel(cl)
results <- foreach(layer = paste0("D", 1:1), .combine = c) %:% # 这个指标只在D1层完整
   foreach(field = c('AWC'), .combine = c) %dopar% # 这个指标只在D1层完整
   {
      library(terra)
      library(openxlsx)
      soil_data <- read.xlsx("HWSD2mdbExtract/HWSD2_layers_sep_filtered.xlsx", sheet = layer)
      soil_raster <- rast("data/HWSD2.bil")
      soil_raster_field <- classify(
         soil_raster, rcl = cbind(as.numeric(soil_data$HWSD2_SMU_ID), soil_data[[field]]), others = NA)
      soil_raster_field[soil_raster_field < 0] <- NA
      names(soil_raster_field) <- paste0(field, "_", layer)
      out_path <- file.path(out_dir, sprintf('%s_%s.tif', field, layer))
      writeRaster(soil_raster_field, out_path, overwrite = TRUE)
      rm(soil_raster, soil_raster_field)
      gc()
      paste(field, layer, "完成")}
stopCluster(cl)
end2 <- Sys.time()
end2 - start2 # ~ 25 min


## 字符型变量栅格 -----------------------------------------------------------------

# 综合D1-D7所有土层，提取各分类变量实际出现的值
all_sheets <- paste0("D", 1:7)
fields_to_process <- c('WRB_PHASES', 'WRB4', 'FAO90', 'DRAINAGE', 'ROOT_DEPTH', 'TEXTURE_USDA')
global_lookups <- list()
for (field in fields_to_process) {
   all_values <- c()
   for (sheet in all_sheets) {
      # 利用 SEQUENCE = 1 的数据（即最主要的土壤类型）
      temp_data <- read.xlsx("HWSD2mdbExtract/HWSD2_layers_sep_filtered.xlsx", sheet = sheet)
      all_values <- c(all_values, as.character(temp_data[[field]]))}
   unique_vals <- sort(unique(na.omit(all_values)))
   global_lookups[[field]] <- data.frame(Symbol = unique_vals)
}
for (field in fields_to_process) { # 导出查找表，用于后续完善
   global_csv_path <- file.path(out_dir, sprintf('%s_lookup.csv', field))
   write.csv(global_lookups[[field]], global_csv_path, row.names = FALSE, fileEncoding = "UTF-8")
}


# 将HWSD2.mdb数据库中D_WRB_PHASES的ID、全称补充到WRB_PHASES查找表里
# 读入D_WRB_PHASES
d_wrb_phases <- read.xlsx('HWSD2mdbExtract/D_WRB_PHASES.xlsx')
d_wrb_phases <- d_wrb_phases %>% mutate(CODE2 = toupper(gsub(" ", "", CODE))) # 去空格后大写
# d_wrb_phases$CODE去重
d_wrb_phases %>% group_by(CODE2) %>% summarise(n = n()) %>% filter(n > 1) %>%
   pull(CODE2) %>% { filter(d_wrb_phases, CODE2 %in% .) }
d_wrb_phases <- d_wrb_phases %>% mutate(VALUE = case_when( # 先修正错误
   CODE == "CRra" ~ "Reducaquic Cryosol",
   CODE == "FLkkca" ~ "Calcaric Akroskeletic Fluvisol",
   CODE == "GYlelv" ~ "Luvic Leptic Gypsisol",
   CODE == "GYlelvkk" ~ "Akroskeletic Luvic Leptic Gypsisol",
   TRUE ~ VALUE)) %>% group_by(CODE) %>% # 再去重
   arrange(ID) %>% slice(1) %>% ungroup()
# d_wrb_phases$VALUE错误修正
d_wrb_phases$VALUE <- trimws(d_wrb_phases$VALUE)
d_wrb_phases$VALUE <- gsub("sols$", "sol", d_wrb_phases$VALUE)
d_wrb_phases$VALUE <- gsub("Gyspsisol", "Gypsisol", d_wrb_phases$VALUE)
d_wrb_phases %>% group_by(VALUE) %>% summarise(n = n()) %>% filter(n > 1) %>%
   pull(VALUE) %>% { filter(d_wrb_phases, VALUE %in% .) }
d_wrb_phases <- d_wrb_phases %>% mutate(VALUE = case_when(
   CODE == "CLkk" ~ "Akroskeletic Calcisol",
   CODE == "LXfrkk" ~ "Akroskeletic Ferric Lixisol",
   CODE == "GLlv" ~ "Luvic Gleysol", TRUE ~ VALUE))
# 读入WRB_PHASES查找表
wrb_phases_lookup <- read.csv(file.path(out_dir, 'WRB_PHASES_lookup.csv'), stringsAsFactors = FALSE)
wrb_phases_lookup <- wrb_phases_lookup %>% mutate(Symbol2 = toupper(gsub(" ", "", Symbol))) # 去空格后大写
# wrb_phases_lookup$Symbol去重
wrb_phases_lookup %>% group_by(Symbol2) %>% summarise(n = n()) %>% filter(n > 1) %>%
   pull(Symbol2) %>% { filter(wrb_phases_lookup, Symbol2 %in% .) }
wrb_phases_lookup <- wrb_phases_lookup %>%
   filter(!Symbol %in% c("Gleuskkk", "Glmokk", "Ksha", "Plmo", "PTlx ", "Pzetle"))
# 匹配D_WRB_PHASES的VALUE、ID，将二者分别重命名为FullName、Value，用于后续栅格制作
wrb_phases_lookup_full <- wrb_phases_lookup %>% left_join(
   d_wrb_phases %>% select(CODE2, VALUE, ID), by = c("Symbol2" = "CODE2")) %>%
   rename(FullName = VALUE, Value = ID)
if (any(is.na(wrb_phases_lookup_full$FullName))) {
   cat("\n仍然未匹配的记录:\n")
   print(wrb_phases_lookup_full %>% filter(is.na(FullName)))
} else {cat("所有记录都成功匹配！\n")}
# 调整WRB_PHASES查找表
wrb_phases_lookup_full %>% group_by(FullName) %>% summarise(n = n()) %>% filter(n > 1) %>%
   pull(FullName) %>% { filter(wrb_phases_lookup_full, FullName %in% .) }
## WRB_PHASES中的ACkkfr和ACfrkk全称一样，保留ACkkfr，去除ACfrkk。
## WRB_PHASES中的le和lp均为Leptic，都暂做保留。
wrb_phases_lookup_full <- wrb_phases_lookup_full %>% filter(Symbol2 != "ACKKFR")
wrb_phases_lookup_full$Symbol <- gsub(" ", "", wrb_phases_lookup_full$Symbol) # 去除Symbol列中的空格
# 导出完善之后的查找表
output_file <- file.path(out_dir, 'WRB_PHASES_lookup_fullname.csv')
write.csv(wrb_phases_lookup_full, output_file, row.names = FALSE)

# 将HWSD2.mdb数据库中D_WRB4的ID、全称补充到WRB4查找表里
# 读入D_WRB4
d_wrb4 <- read.xlsx('HWSD2mdbExtract/D_WRB4.xlsx')
d_wrb4 <- d_wrb4 %>% mutate(CODE2 = toupper(gsub(" ", "", CODE))) # 去空格后大写
# d_wrb4$CODE去重
d_wrb4 %>% group_by(CODE2) %>% summarise(n = n()) %>% filter(n > 1) %>%
   pull(CODE2) %>% { filter(d_wrb4, CODE2 %in% .) }
d_wrb4 <- d_wrb4 %>%  group_by(CODE) %>% arrange(ID) %>% slice(1) %>% ungroup()
# d_wrb4$VALUE错误修正
d_wrb4$VALUE <- trimws(d_wrb4$VALUE)
d_wrb4$VALUE <- gsub("(?i)(sol)$", "\\1s", d_wrb4$VALUE)
d_wrb4$VALUE <- gsub("\\bSolonchak\\b", "Solonchaks", d_wrb4$VALUE)
d_wrb4 %>% group_by(VALUE) %>% summarise(n = n()) %>% filter(n > 1) %>%
   pull(VALUE) %>% { filter(d_wrb4, VALUE %in% .) }
d_wrb4 <- d_wrb4 %>% mutate(VALUE = case_when(
   CODE == "ANdy" ~ "Dystric Andosols", TRUE ~ VALUE))
## 此处CODE为SGgl是错的，应为SCgl。鉴于SGgl未在所有土层中实际出现，故不再处理
# 读入WRB4查找表
wrb4_lookup <- read.csv(file.path(out_dir, 'WRB4_lookup.csv'), stringsAsFactors = FALSE)
wrb4_lookup <- wrb4_lookup %>% mutate(Symbol2 = toupper(gsub(" ", "", Symbol))) # 去空格后大写
# wrb4_lookup$Symbol去重
wrb4_lookup %>% group_by(Symbol2) %>% summarise(n = n()) %>% filter(n > 1) %>%
   pull(Symbol2) %>% { filter(wrb4_lookup, Symbol2 %in% .) }
wrb4_lookup <- wrb4_lookup %>% filter(!Symbol %in% c("ARse ", "Glar", "PTlx "))
# 匹配D_WRB4的VALUE、ID，将二者分别重命名为FullName、Value，用于后续栅格制作
wrb4_lookup_full <- wrb4_lookup %>% left_join(
   d_wrb4 %>% select(CODE2, VALUE, ID), by = c("Symbol2" = "CODE2")) %>%
   rename(FullName = VALUE, Value = ID)
if (any(is.na(wrb4_lookup_full$FullName))) {
   cat("\n仍然未匹配的记录:\n")
   print(wrb4_lookup_full %>% filter(is.na(FullName)))
} else {cat("所有记录都成功匹配！\n")}
# 调整WRB4查找表
wrb4_lookup_full %>% group_by(FullName) %>% summarise(n = n()) %>% filter(n > 1) %>%
   pull(FullName) %>% { filter(wrb4_lookup_full, FullName %in% .) }
wrb4_lookup_full$Symbol <- gsub(" ", "", wrb4_lookup_full$Symbol) # 去除Symbol列中的空格
# 导出完善之后的查找表
output_file <- file.path(out_dir, 'WRB4_lookup_fullname.csv')
write.csv(wrb4_lookup_full, output_file, row.names = FALSE)

# 将HWSD2.mdb数据库中D_FAO90的ID、全称补充到FAO90查找表里
# 读入D_FAO90
d_fao90 <- read.xlsx('HWSD2mdbExtract/D_FAO90.xlsx')
d_fao90 <- d_fao90 %>% mutate(CODE2 = toupper(gsub(" ", "", CODE))) # 去空格后大写
d_fao90 %>% group_by(CODE2) %>% summarise(n = n()) %>% filter(n > 1) %>%
   pull(CODE2) %>% { filter(d_fao90, CODE2 %in% .) }
d_fao90$VALUE <- trimws(d_fao90$VALUE)
d_fao90 %>% group_by(VALUE) %>% summarise(n = n()) %>% filter(n > 1) %>%
   pull(VALUE) %>% { filter(d_fao90, VALUE %in% .) }
# 读入FAO90查找表
fao90_lookup <- read.csv(file.path(out_dir, 'FAO90_lookup.csv'), stringsAsFactors = FALSE)
fao90_lookup <- fao90_lookup %>% mutate(Symbol2 = toupper(gsub(" ", "", Symbol))) # 去空格后大写
fao90_lookup %>% group_by(Symbol2) %>% summarise(n = n()) %>% filter(n > 1) %>%
   pull(Symbol2) %>% { filter(fao90_lookup, Symbol2 %in% .) }
# 匹配D_FAO90的VALUE、SYMBOL，将二者分别重命名为FullName、Value，用于后续栅格制作
fao90_lookup_full <- fao90_lookup %>% left_join(
   d_fao90 %>% select(CODE2, VALUE, SYMBOL), by = c("Symbol2" = "CODE2")) %>%
   rename(FullName = VALUE, Value = SYMBOL)
if (any(is.na(fao90_lookup_full$FullName))) {
   cat("\n仍然未匹配的记录:\n")
   print(fao90_lookup_full %>% filter(is.na(FullName)))
} else {cat("所有记录都成功匹配！\n")}
# 调整FAO90查找表
fao90_lookup_full %>% group_by(FullName) %>% summarise(n = n()) %>% filter(n > 1) %>%
   pull(FullName) %>% { filter(fao90_lookup_full, FullName %in% .) }
fao90_lookup_full$Symbol <- gsub(" ", "", fao90_lookup_full$Symbol) # 去除Symbol列中的空格
# 导出完善之后的查找表
output_file <- file.path(out_dir, 'FAO90_lookup_fullname.csv')
write.csv(fao90_lookup_full, output_file, row.names = FALSE)

# 将HWSD2.mdb数据库中D_DRAINAGE的ID、全称补充到DRAINAGE查找表里
# 读入D_DRAINAGE
d_drainage <- read.xlsx('HWSD2mdbExtract/D_DRAINAGE.xlsx')
d_drainage$VALUE <- trimws(d_drainage$VALUE)
# 读入DRAINAGE查找表
drainage_lookup <- read.csv(file.path(out_dir, 'DRAINAGE_lookup.csv'), stringsAsFactors = FALSE)
# 匹配D_DRAINAGE的VALUE、SYMBOL，将二者分别重命名为FullName、Value，用于后续栅格制作
drainage_lookup_full <- drainage_lookup %>% left_join(
   d_drainage %>% select(CODE, VALUE, SYMBOL), by = c("Symbol" = "CODE")) %>%
   rename(FullName = VALUE, Value = SYMBOL)
# 导出完善之后的查找表
output_file <- file.path(out_dir, 'DRAINAGE_lookup_fullname.csv')
write.csv(drainage_lookup_full, output_file, row.names = FALSE)

# 将HWSD2.mdb数据库中D_ROOT_DEPTH的ID、全称补充到ROOT_DEPTH查找表里
# 读入D_ROOT_DEPTH
d_root_depth <- read.xlsx('HWSD2mdbExtract/D_ROOT_DEPTH.xlsx')
d_root_depth$VALUE <- gsub("([0-9]+)cm", "\\1 cm", d_root_depth$VALUE, ignore.case = TRUE)
d_root_depth$VALUE <- gsub("\\s+", " ", d_root_depth$VALUE)
# 读入ROOT_DEPTH查找表
root_depth_lookup <- read.csv(file.path(out_dir, 'ROOT_DEPTH_lookup.csv'), stringsAsFactors = FALSE)
# 匹配D_ROOT_DEPTH的VALUE，将二者分别重命名为FullName，用于后续栅格制作
root_depth_lookup_full <- root_depth_lookup %>% left_join(
   d_root_depth %>% select(CODE, VALUE), by = c("Symbol" = "CODE")) %>% rename(FullName = VALUE)
root_depth_lookup_full$Value <- root_depth_lookup_full$Symbol
# 导出完善之后的查找表
output_file <- file.path(out_dir, 'ROOT_DEPTH_lookup_fullname.csv')
write.csv(root_depth_lookup_full, output_file, row.names = FALSE)

# 将HWSD2.mdb数据库中D_TEXTURE_USDA的ID、全称补充到TEXTURE_USDA查找表里
# 读入D_TEXTURE_USDA
d_texture_usda <- read.xlsx('HWSD2mdbExtract/D_TEXTURE_USDA.xlsx')
# 读入TEXTURE_USDA查找表
texture_usda_lookup <- read.csv(file.path(out_dir, 'TEXTURE_USDA_lookup.csv'), stringsAsFactors = FALSE)
# 匹配D_TEXTURE_USDA的VALUE，将二者分别重命名为FullName，用于后续栅格制作
texture_usda_lookup_full <- texture_usda_lookup %>% left_join(
   d_texture_usda %>% select(CODE, VALUE), by = c("Symbol" = "CODE")) %>% rename(FullName = VALUE)
texture_usda_lookup_full$Value <- texture_usda_lookup_full$Symbol
# 导出完善之后的查找表
output_file <- file.path(out_dir, 'TEXTURE_USDA_lookup_fullname.csv')
write.csv(texture_usda_lookup_full, output_file, row.names = FALSE)


# 重新读入各分类变量对应表，用于栅格制作
fields_to_process <- c('WRB_PHASES', 'WRB4', 'FAO90', 'DRAINAGE', 'ROOT_DEPTH', 'TEXTURE_USDA')
global_lookups_fullname <- list()
for (field in fields_to_process) {
   global_csv_path <- file.path(out_dir, sprintf('%s_lookup_fullname.csv', field))
   if (file.exists(global_csv_path)) {
      global_lookups_fullname[[field]] <- read.csv(global_csv_path, fileEncoding = "UTF-8")
   } else {stop(paste("查找表文件不存在:", global_csv_path))}
}


start3 <- Sys.time()
all_sheets <- paste0("D", 1:7)
fields_to_process <- c('DRAINAGE', 'TEXTURE_USDA')
cl <- makeCluster(detectCores() - 2)
registerDoParallel(cl)
clusterExport(cl, c("global_lookups_fullname", "out_dir", "fields_to_process", "all_sheets"))
results <- foreach(layer = all_sheets, .combine = c) %:%
   foreach(field = fields_to_process, .combine = c) %dopar% {
      library(terra)
      library(openxlsx)
      soil_data <- read.xlsx("HWSD2mdbExtract/HWSD2_layers_sep_filtered.xlsx", sheet = layer)
      soil_raster <- rast("data/HWSD2.bil")
      lookup <- global_lookups_fullname[[field]]
      soil_data$field_id <- lookup$Value[match(soil_data[[field]], lookup$Symbol)]
      soil_raster_field <- classify(
         soil_raster, rcl = cbind(as.numeric(soil_data$HWSD2_SMU_ID), soil_data$field_id), others = NA)
      names(soil_raster_field) <- paste0(field, "_", layer)
      levels(soil_raster_field) <- lookup[, c("Value", "Symbol", "FullName")] # 将Symbol作为标签
      out_path <- file.path(out_dir, sprintf('%s_%s.tif', field, layer))
      writeRaster(soil_raster_field, out_path, overwrite = TRUE, datatype = "INT2U")
      rm(soil_raster, soil_raster_field, soil_data)
      gc()
      paste(field, layer, "完成")}
stopCluster(cl)
end3 <- Sys.time()
end3 - start3 # ~ 1.1 h

start4 <- Sys.time()
all_sheets <- paste0("D", 1:1) # ROOT_DEPTH只在D1层出现
fields_to_process <- c('ROOT_DEPTH')
cl <- makeCluster(detectCores() - 2)
registerDoParallel(cl)
clusterExport(cl, c("global_lookups_fullname", "out_dir", "fields_to_process", "all_sheets"))
results <- foreach(layer = all_sheets, .combine = c) %:%
   foreach(field = fields_to_process, .combine = c) %dopar% {
      library(terra)
      library(openxlsx)
      soil_data <- read.xlsx("HWSD2mdbExtract/HWSD2_layers_sep_filtered.xlsx", sheet = layer)
      soil_raster <- rast("data/HWSD2.bil")
      lookup <- global_lookups_fullname[[field]]
      soil_data$field_id <- lookup$Value[match(soil_data[[field]], lookup$Symbol)]
      soil_raster_field <- classify(
         soil_raster, rcl = cbind(as.numeric(soil_data$HWSD2_SMU_ID), soil_data$field_id), others = NA)
      names(soil_raster_field) <- paste0(field, "_", layer)
      levels(soil_raster_field) <- lookup[, c("Value", "Symbol", "FullName")] # 将Symbol作为标签
      out_path <- file.path(out_dir, sprintf('%s_%s.tif', field, layer))
      writeRaster(soil_raster_field, out_path, overwrite = TRUE, datatype = "INT2U")
      rm(soil_raster, soil_raster_field, soil_data)
      gc()
      paste(field, layer, "完成")}
stopCluster(cl)
end4 <- Sys.time()
end4 - start4 # ~ 18 min

start5 <- Sys.time()
all_sheets <- paste0("D", 1:7)
fields_to_process <- c('WRB4', 'FAO90')
cl <- makeCluster(detectCores() - 2)
registerDoParallel(cl)
clusterExport(cl, c("global_lookups_fullname", "out_dir", "fields_to_process", "all_sheets"))
results <- foreach(layer = all_sheets, .combine = c) %:%
   foreach(field = fields_to_process, .combine = c) %dopar% {
      library(terra)
      library(openxlsx)
      soil_data <- read.xlsx("HWSD2mdbExtract/HWSD2_layers_sep_filtered.xlsx", sheet = layer)
      soil_raster <- rast("data/HWSD2.bil")
      lookup <- global_lookups_fullname[[field]]

      soil_data$new_field <- toupper(gsub(" ", "", soil_data[[field]]))
      soil_data$field_id <- lookup$Value[match(soil_data$new_field, lookup$Symbol2)]

      soil_raster_field <- classify(
         soil_raster, rcl = cbind(as.numeric(soil_data$HWSD2_SMU_ID), soil_data$field_id), others = NA)
      names(soil_raster_field) <- paste0(field, "_", layer)
      levels(soil_raster_field) <- lookup[, c("Value", "Symbol", "FullName")] # 将Symbol作为标签
      out_path <- file.path(out_dir, sprintf('%s_%s.tif', field, layer))
      writeRaster(soil_raster_field, out_path, overwrite = TRUE, datatype = "INT2U")
      rm(soil_raster, soil_raster_field, soil_data)
      gc()
      paste(field, layer, "完成")}
stopCluster(cl)
end5 <- Sys.time()
end5 - start5 # ~ 1.1 h

start6 <- Sys.time()
all_sheets <- paste0("D", 1:7)
fields_to_process <- c('WRB_PHASES')
cl <- makeCluster(detectCores() - 2)
registerDoParallel(cl)
clusterExport(cl, c("global_lookups_fullname", "out_dir", "fields_to_process", "all_sheets"))
results <- foreach(layer = all_sheets, .combine = c) %:%
   foreach(field = fields_to_process, .combine = c) %dopar% {
      library(terra)
      library(openxlsx)
      soil_data <- read.xlsx("HWSD2mdbExtract/HWSD2_layers_sep_filtered.xlsx", sheet = layer)
      soil_raster <- rast("data/HWSD2.bil")
      lookup <- global_lookups_fullname[[field]]

      # soil_data$WRB_PHASES的空缺值用WRB4列数据替代
      soil_data[[field]] <- ifelse(is.na(soil_data[[field]]), soil_data$WRB4, soil_data[[field]])
      soil_data$new_field <- toupper(gsub(" ", "", soil_data[[field]]))
      soil_data$new_field[soil_data$new_field == "ACKKFR"] <- "ACFRKK" # ACKKFR替换为ACFRKK。
      soil_data$field_id <- lookup$Value[match(soil_data$new_field, lookup$Symbol2)]

      soil_raster_field <- classify(
         soil_raster, rcl = cbind(as.numeric(soil_data$HWSD2_SMU_ID), soil_data$field_id), others = NA)
      names(soil_raster_field) <- paste0(field, "_", layer)
      levels(soil_raster_field) <- lookup[, c("Value", "Symbol", "FullName")] # 将Symbol作为标签
      out_path <- file.path(out_dir, sprintf('%s_%s.tif', field, layer))
      writeRaster(soil_raster_field, out_path, overwrite = TRUE, datatype = "INT2U")
      rm(soil_raster, soil_raster_field, soil_data)
      gc()
      paste(field, layer, "完成")}
stopCluster(cl)
end6 <- Sys.time()
end6 - start6 # ~ 31 min


