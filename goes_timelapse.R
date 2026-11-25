library(terra)
library(rvest)
library(httr)
library(stringr)
library(av)

# ==============================================================================
# 1. CONFIGURAÇÕES
# ==============================================================================
base_url <- "http://server/GOES-R-CMI-Imagery/"
bandas <- c(
  B01 = "Band01/",
  B02 = "Band02-0.5km/",
  B03 = "Band03/",
  B13 = "Band13/"
)

dir_trabalho <- "/home/claiton/GOES_Timelapse"
dir_nc       <- file.path(dir_trabalho, "nc_temp")
dir_frames   <- file.path(dir_trabalho, "frames_png")
arquivo_mp4  <- file.path(dir_trabalho, "goes_ultimas_3h.mp4")

dir.create(dir_nc, recursive = TRUE, showWarnings = FALSE)
dir.create(dir_frames, recursive = TRUE, showWarnings = FALSE)

# Janela de tempo: 18 imagens (3 horas com intervalo de 10 min)
n_imagens <- 18

# Altura do satélite GOES em metros (correção de radianos -> metros)
H_GOES <- 35786023

# Grade de destino (América do Sul / Brasil em ~2 km)
ext_recorte <- ext(-85, -30, -35, 10)
target_grid <- rast(ext_recorte, res = 0.02, crs = "EPSG:4326")

# ==============================================================================
# 2. LISTAR ARQUIVOS DISPONÍVEIS NO SERVIDOR E FILTRAR AS ÚLTIMAS 3 HORAS
# ==============================================================================
listar_remoto <- function(url_banda) {
  pg <- tryCatch(read_html(url_banda), error = function(e) return(NULL))
  if (is.null(pg)) return(character(0))
  links <- html_attr(html_nodes(pg, "a"), "href")
  links[grepl("\\.nc$", links, ignore.case = TRUE)]
}

listas_remotas <- lapply(paste0(base_url, bandas), listar_remoto)
names(listas_remotas) <- names(bandas)

extrair_timestamp <- function(nomes) {
  str_extract(basename(nomes), "s\\d{11}")
}

ts_list <- lapply(listas_remotas, extrair_timestamp)
ts_comuns <- sort(Reduce(intersect, ts_list), decreasing = FALSE)

if (length(ts_comuns) == 0) {
  stop("Nenhum horário completo com as 4 bandas encontrado no servidor.")
}

ts_alvo <- tail(ts_comuns, n_imagens)

# ==============================================================================
# 3. LIMPEZA AUTOMÁTICA DE ARQUIVOS ANTIGOS
# ==============================================================================
for (arq in list.files(dir_nc, full.names = TRUE)) {
  ts_arq <- str_extract(basename(arq), "s\\d{11}")
  if (is.na(ts_arq) || !(ts_arq %in% ts_alvo)) file.remove(arq)
}

for (arq in list.files(dir_frames, full.names = TRUE)) {
  ts_arq <- str_extract(basename(arq), "s\\d{11}")
  if (is.na(ts_arq) || !(ts_arq %in% ts_alvo)) file.remove(arq)
}

# ==============================================================================
# 4. DOWNLOAD DOS ARQUIVOS NOVOS DA JANELA DE 3 HORAS
# ==============================================================================
for (b in names(bandas)) {
  arqs_banda <- listas_remotas[[b]]
  for (ts in ts_alvo) {
    arq_match <- arqs_banda[grepl(ts, arqs_banda)][1]
    if (!is.na(arq_match)) {
      destino <- file.path(dir_nc, basename(arq_match))
      if (!file.exists(destino)) {
        url_full <- paste0(base_url, bandas[[b]], basename(arq_match))
        message("Baixando: ", basename(arq_match))
        try(GET(url_full, write_disk(destino, overwrite = TRUE), timeout(120)), silent = TRUE)
      }
    }
  }
}

# ==============================================================================
# 5. COMPOSIÇÃO COLORIDA (GEOCOLOR / TRUE COLOR + IR NOTURNO) POR HORÁRIO
# ==============================================================================
carregar_e_projetar <- function(arquivo_nc, grade_destino) {
  r <- rast(arquivo_nc, subds = "CMI")
  if (abs(xmax(r)) < 10) ext(r) <- ext(r) * H_GOES
  project(r, grade_destino, method = "bilinear")
}

for (ts in ts_alvo) {
  png_saida <- file.path(dir_frames, paste0("frame_", ts, ".png"))
  if (file.exists(png_saida)) next
  
  f_b01 <- list.files(dir_nc, pattern = paste0("C01.*", ts, ".*\\.nc$"), full.names = TRUE)[1]
  f_b02 <- list.files(dir_nc, pattern = paste0("C02.*", ts, ".*\\.nc$"), full.names = TRUE)[1]
  f_b03 <- list.files(dir_nc, pattern = paste0("C03.*", ts, ".*\\.nc$"), full.names = TRUE)[1]
  f_b13 <- list.files(dir_nc, pattern = paste0("C13.*", ts, ".*\\.nc$"), full.names = TRUE)[1]
  
  if (any(is.na(c(f_b01, f_b02, f_b03, f_b13)))) next
  
  message("Processando frame: ", ts)
  
  r01 <- carregar_e_projetar(f_b01, target_grid)
  r02 <- carregar_e_projetar(f_b02, target_grid)
  r03 <- carregar_e_projetar(f_b03, target_grid)
  r13 <- carregar_e_projetar(f_b13, target_grid)
  
  clamp_gamma <- function(r, gamma = 1.6) {
    r <- clamp(r, 0, 1)
    return(r^(1 / gamma))
  }
  
  b01_c <- clamp_gamma(r01)
  b02_c <- clamp_gamma(r02)
  b03_c <- clamp_gamma(r03)
  
  verde_sint <- 0.45 * b02_c + 0.10 * b03_c + 0.45 * b01_c
  
  ir_norm <- clamp((300 - r13) / (300 - 200), 0, 1)
  noite   <- b02_c < 0.05
  
  R_final <- ifel(noite, ir_norm * 0.6, b02_c) * 255
  G_final <- ifel(noite, ir_norm * 0.7, verde_sint) * 255
  B_final <- ifel(noite, ir_norm * 0.9, b01_c) * 255
  
  rgb_stack <- c(R_final, G_final, B_final)
  
  ano <- substr(ts, 2, 5)
  doy <- as.integer(substr(ts, 6, 8))
  hh  <- substr(ts, 9, 10)
  mm  <- substr(ts, 11, 12)
  dt_utc <- as.POSIXct(paste0(as.Date(doy - 1, origin = paste0(ano, "-01-01")), " ", hh, ":", mm, ":00"), tz = "UTC")
  dt_brt <- format(dt_utc, tz = "America/Sao_Paulo", usetz = FALSE)
  selo   <- paste0("GOES-19 | ", format(as.POSIXct(dt_brt), "%d/%m %H:%M"), " BRT")

  png(png_saida, width = 1200, height = 980, res = 120)
  par(mar = c(0, 0, 0, 0), oma = c(0, 0, 0, 0))
  plotRGB(rgb_stack, r = 1, g = 2, b = 3, stretch = "lin", axes = FALSE, mar = c(0, 0, 0, 0))
  par(fig = c(0, 1, 0, 1), usr = c(0, 1, 0, 1), mar = c(0, 0, 0, 0), new = TRUE)
  plot.new()
  usr <- par("usr")
  legend(x = usr[2] - 0.012, y = usr[4] - 0.015, legend = selo,
         xjust = 1, yjust = 1, bty = "o",
         bg = rgb(0, 0, 0, 0.55), box.col = rgb(1, 1, 1, 0.25),
         text.col = "white", cex = 0.72, x.intersp = 0.4, y.intersp = 0.6)
  dev.off()
  
  rm(r01, r02, r03, r13, b01_c, b02_c, b03_c, verde_sint, ir_norm, rgb_stack)
  gc()
}

# ==============================================================================
# 6. ATUALIZAÇÃO DO VÍDEO TIME-LAPSE (.MP4) E PUBLICAÇÃO NO GITHUB PAGES
# ==============================================================================
frames_prontos <- sort(list.files(dir_frames, pattern = "\\.png$", full.names = TRUE))

if (length(frames_prontos) >= 2) {
  av_encode_video(
    input = frames_prontos,
    output = arquivo_mp4,
    framerate = 4,
    verbose = FALSE
  )
  message("Time-lapse atualizado com sucesso em: ", arquivo_mp4)
  
  cmd_git <- paste(
    "cd /home/claiton/GOES_Timelapse &&",
    "git add goes_ultimas_3h.mp4 index.html &&",
    "git commit --amend -m 'Atualizacao GOES' &&",
    "git push -f origin main"
  )
  system(cmd_git)
}
