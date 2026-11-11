import Hls from "hls.js"

// Plays a video directly when the browser supports the file, otherwise (or if
// direct playback fails) through the server's on-the-fly HLS transcoder.
export const Player = {
  mounted() {
    this.video = this.el.querySelector("video")
    this.notice = this.el.querySelector("[data-transcode-notice]")
    this.usingHls = false

    const {mode, direct, mime} = this.el.dataset
    const browserSaysNo = mime && this.video.canPlayType(mime) === ""

    if (mode === "direct" && !browserSaysNo) {
      this.onError = () => {
        const err = this.video.error
        // 3 = decode error, 4 = source not supported
        if (!this.usingHls && err && (err.code === 3 || err.code === 4)) {
          console.info("Direct playback failed, switching to transcoding", err)
          this.startHls(this.video.currentTime)
        }
      }
      this.video.addEventListener("error", this.onError)
      this.video.src = direct
    } else {
      this.startHls(0)
    }
  },

  startHls(position) {
    const url = this.el.dataset.hls
    const wasPlaying = !this.video.paused || this.el.dataset.autoplay === "true"
    this.usingHls = true
    if (this.notice) this.notice.hidden = false

    if (Hls.isSupported()) {
      this.hls = new Hls({
        startPosition: position || 0,
        maxBufferLength: 30,
        backBufferLength: 60,
        // Seeking far ahead restarts the encoder; give it time.
        fragLoadPolicy: {
          default: {
            maxTimeToFirstByteMs: 90000,
            maxLoadTimeMs: 180000,
            timeoutRetry: {maxNumRetry: 2, retryDelayMs: 0, maxRetryDelayMs: 0},
            errorRetry: {maxNumRetry: 3, retryDelayMs: 1000, maxRetryDelayMs: 8000},
          },
        },
      })
      this.hls.loadSource(url)
      this.hls.attachMedia(this.video)
      this.hls.on(Hls.Events.MANIFEST_PARSED, () => {
        if (wasPlaying) this.video.play().catch(() => {})
      })
      this.hls.on(Hls.Events.ERROR, (_event, data) => {
        if (data.fatal && data.type === Hls.ErrorTypes.MEDIA_ERROR) this.hls.recoverMediaError()
      })
    } else if (this.video.canPlayType("application/vnd.apple.mpegurl")) {
      // Safari plays HLS natively.
      this.video.src = url
      if (position) this.video.addEventListener("loadedmetadata", () => { this.video.currentTime = position }, {once: true})
      if (wasPlaying) this.video.play().catch(() => {})
    }
  },

  destroyed() {
    if (this.hls) this.hls.destroy()
    if (this.onError) this.video.removeEventListener("error", this.onError)
  },
}
