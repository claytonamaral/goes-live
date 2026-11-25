# 🛰️ GOES-19 GeoColor Automated Time-Lapse

**Live Animation:** [https://claytonamaral.github.io/goes-live/](https://claytonamaral.github.io/goes-live/)

An automated end-to-end pipeline written in **R** on **Debian GNU/Linux** that ingests near-real-time GOES-19 ABI Level-2 imagery from a local GEONETCast receiving station, generates GeoColor (True Color + Nighttime IR) composites, encodes a rolling 3-hour MP4 time-lapse, and publishes it automatically to GitHub Pages every 10 minutes.

---

## ⚙️ How It Works

1. **Automated Ingestion:** Queries the local GEONETCast HTTP server every 10 minutes and pairs timestamps where all four required ABI bands (`Band 01`, `Band 02`, `Band 03`, and `Band 13`) are available.
2. **Rolling Window & Storage Cleanup:** Maintains a strict 3-hour window (18 frames at 10-minute intervals), automatically purging older NetCDF and PNG files to minimize disk and RAM usage.
3. **GeoColor Composite & Nighttime Blending:**
   * Reprojects and crops the full-disk imagery to South America (`EPSG:4326`).
   * Synthesizes the missing green channel using the standard NOAA/CIMSS formula:
     $$\text{Green}_{\text{synthetic}} = 0.45 \times \text{B02} + 0.10 \times \text{B03} + 0.45 \times \text{B01}$$
   * Blends Band 13 (`10.3 µm` Clean IR) into low-light/nighttime regions so cloud systems remain visible 24/7.
4. **Video Encoding & Continuous Deployment:** Encodes the frames into `goes_ultimas_3h.mp4` via `FFmpeg`/`av` and pushes the updated video to GitHub Pages.

---

## 🖥️ System & Dependencies

* **OS:** Debian GNU/Linux 12 (Bookworm)
* **Scheduler:** `cron` + `flock` (prevents overlapping runs)
* **System Libraries:** `r-base`, `ffmpeg`, `libgdal-dev`, `libproj-dev`, `libgeos-dev`, `libavfilter-dev`
* **R Packages:** `terra`, `rvest`, `httr`, `stringr`, `av`

### Crontab Configuration
```cron
*/10 * * * * /usr/bin/flock -n /tmp/goes_timelapse.lock /usr/bin/Rscript /path/to/goes_timelapse.R >> /path/to/GOES_Timelapse/log.txt 2>&1
```

---

## 📁 Repository Structure

* `index.html` — Lightweight dark-mode web player with automatic 10-minute refresh.
* `goes_ultimas_3h.mp4` — Rolling 3-hour GOES-19 GeoColor time-lapse animation.
* `goes_timelapse.R` — Main R processing and deployment script.
