// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/hive"
import topbar from "../vendor/topbar"
import { Terminal as XTerm } from "../vendor/xterm/xterm.mjs"
import { FitAddon } from "../vendor/xterm/addon-fit.mjs"

const MENTION_PATTERN = /@([A-Za-z0-9][A-Za-z0-9_-]{0,30})/g
const WORD_CHAR_PATTERN = /[A-Za-z0-9_-]/

const escapeHtml = (value = "") => value
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;")
  .replaceAll("'", "&#39;")

const parseAgentProfiles = (raw) => {
  try {
    const parsed = JSON.parse(raw || "{}")
    return parsed && typeof parsed === "object" ? parsed : {}
  } catch {
    return {}
  }
}

const truncateText = (value = "", maxLength = 140) => {
  const normalized = value.replace(/\s+/g, " ").trim()

  if (normalized.length <= maxLength) {
    return normalized
  }

  return `${normalized.slice(0, maxLength).trimEnd()}...`
}

const renderMentionMarkup = (text, profiles) => {
  if (!text) return "<span class=\"ui-chat-composer__ghost\">\u200b</span>"

  let html = ""
  let lastIndex = 0
  MENTION_PATTERN.lastIndex = 0

  for (let match; (match = MENTION_PATTERN.exec(text)); ) {
    const mentionIndex = match.index
    const previousChar = mentionIndex === 0 ? "" : text[mentionIndex - 1]

    if (previousChar && WORD_CHAR_PATTERN.test(previousChar)) {
      continue
    }

    const fullMatch = match[0]
    const agentName = match[1]

    html += escapeHtml(text.slice(lastIndex, mentionIndex))

    if (profiles[agentName]) {
      html += `<span class="ui-mention">${escapeHtml(fullMatch)}</span>`
    } else {
      html += escapeHtml(fullMatch)
    }

    lastIndex = mentionIndex + fullMatch.length
  }

  html += escapeHtml(text.slice(lastIndex))

  if (text.endsWith("\n")) {
    html += "\u200b"
  }

  return html
}

const enhanceMentionsInElement = (root, profiles) => {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      if (!node.nodeValue || !node.nodeValue.includes("@")) {
        return NodeFilter.FILTER_REJECT
      }

      const parent = node.parentElement

      if (!parent || parent.closest("a, code, pre, button, .ui-mention")) {
        return NodeFilter.FILTER_REJECT
      }

      return NodeFilter.FILTER_ACCEPT
    }
  })

  const textNodes = []

  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    textNodes.push(node)
  }

  textNodes.forEach((node) => {
    const text = node.nodeValue
    const fragment = document.createDocumentFragment()
    let lastIndex = 0
    let hasMention = false

    MENTION_PATTERN.lastIndex = 0

    for (let match; (match = MENTION_PATTERN.exec(text)); ) {
      const mentionIndex = match.index
      const previousChar = mentionIndex === 0 ? "" : text[mentionIndex - 1]

      if (previousChar && WORD_CHAR_PATTERN.test(previousChar)) {
        continue
      }

      const fullMatch = match[0]
      const agentName = match[1]
      const profile = profiles[agentName]

      if (!profile) {
        continue
      }

      hasMention = true
      fragment.append(document.createTextNode(text.slice(lastIndex, mentionIndex)))

      const button = document.createElement("button")
      button.type = "button"
      button.className = "ui-mention"
      button.dataset.agentName = agentName
      button.textContent = fullMatch
      fragment.append(button)

      lastIndex = mentionIndex + fullMatch.length
    }

    if (!hasMention) {
      return
    }

    fragment.append(document.createTextNode(text.slice(lastIndex)))
    node.parentNode.replaceChild(fragment, node)
  })
}

const MentionProfileCard = {
  ensure() {
    if (this.el) return

    const card = document.createElement("div")
    card.className = "ui-agent-profile-card hidden"
    card.setAttribute("role", "dialog")
    card.setAttribute("aria-live", "polite")

    card.addEventListener("mouseenter", () => {
      if (this.hideTimer) {
        clearTimeout(this.hideTimer)
        this.hideTimer = null
      }
    })

    card.addEventListener("mouseleave", () => {
      if (!this.sticky) this.scheduleHide()
    })

    document.addEventListener("click", (event) => {
      if (!this.el || this.el.classList.contains("hidden")) return
      if (this.anchor?.contains(event.target) || this.el.contains(event.target)) return
      this.hide()
    })

    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape") this.hide()
    })

    document.body.appendChild(card)
    this.el = card
  },

  render(profile) {
    const description = profile.description?.trim() || "No description"
    const personality = truncateText(profile.personality || "", 120)
    const personalitySection = personality
      ? `
      <div class="ui-agent-profile-card__section">
        <p class="ui-agent-profile-card__label">Personality</p>
        <p class="ui-agent-profile-card__text">${escapeHtml(personality)}</p>
      </div>
    `
      : ""

    this.el.innerHTML = `
      <div class="ui-agent-profile-card__header">
        <p class="ui-agent-profile-card__eyebrow">Agent</p>
        <h4 class="ui-agent-profile-card__title">${escapeHtml(profile.name)}</h4>
      </div>
      <div class="ui-agent-profile-card__section">
        <p class="ui-agent-profile-card__label">Description</p>
        <p class="ui-agent-profile-card__text">${escapeHtml(description)}</p>
      </div>
      ${personalitySection}
    `
  },

  position(anchor) {
    const rect = anchor.getBoundingClientRect()
    const cardRect = this.el.getBoundingClientRect()
    const top = Math.min(window.innerHeight - cardRect.height - 12, rect.bottom + 10)
    const left = Math.min(window.innerWidth - cardRect.width - 12, Math.max(12, rect.left))

    this.el.style.top = `${Math.max(12, top)}px`
    this.el.style.left = `${left}px`
  },

  show(anchor, profile, sticky = false) {
    this.ensure()

    if (this.hideTimer) {
      clearTimeout(this.hideTimer)
      this.hideTimer = null
    }

    this.anchor = anchor
    this.sticky = sticky
    this.render(profile)
    this.el.classList.remove("hidden")
    this.position(anchor)
  },

  scheduleHide() {
    if (this.sticky) return

    if (this.hideTimer) clearTimeout(this.hideTimer)

    this.hideTimer = setTimeout(() => this.hide(), 120)
  },

  hide() {
    if (!this.el) return
    if (this.hideTimer) {
      clearTimeout(this.hideTimer)
      this.hideTimer = null
    }

    this.anchor = null
    this.sticky = false
    this.el.classList.add("hidden")
  }
}

const ImageLightbox = {
  show(src) {
    if (this.el) this.hide()

    const overlay = document.createElement("div")
    overlay.className = "ui-lightbox"

    const closeBtn = document.createElement("button")
    closeBtn.className = "ui-lightbox__close"
    closeBtn.innerHTML = "&#215;"
    closeBtn.setAttribute("aria-label", "Close")
    closeBtn.addEventListener("click", (e) => { e.stopPropagation(); this.hide() })
    overlay.appendChild(closeBtn)

    const img = document.createElement("img")
    img.className = "ui-lightbox__img"
    img.src = src
    overlay.appendChild(img)

    overlay.addEventListener("click", () => this.hide())

    this._onKeydown = (e) => {
      if (e.key === "Escape") this.hide()
    }
    document.addEventListener("keydown", this._onKeydown)

    document.body.appendChild(overlay)
    this.el = overlay
  },

  hide() {
    if (!this.el) return
    document.removeEventListener("keydown", this._onKeydown)
    this.el.remove()
    this.el = null
  }
}

const Hooks = {
  Terminal: {
    mounted() {
      this.term = new XTerm({
        cursorBlink: true,
        fontFamily: "'JetBrains Mono', 'SFMono-Regular', 'IBM Plex Mono', 'Cascadia Code', monospace",
        fontSize: 14,
        lineHeight: 1.15,
        theme: {
          background: '#0a0a0f',
          foreground: '#d4d4d8',
          cursor: '#d4d4d8',
          selectionBackground: 'rgba(96, 165, 250, 0.3)',
        }
      })
      this.fitAddon = new FitAddon()
      this.term.loadAddon(this.fitAddon)
      this.term.open(this.el)

      // Delay fit until the container is fully laid out
      requestAnimationFrame(() => {
        this.fitAddon.fit()
        const { cols, rows } = this.term
        this.pushEvent("terminal_resize", { cols, rows })
      })

      // Receive output from server
      this.handleEvent("terminal_output", ({ data }) => {
        this.term.write(Uint8Array.from(atob(data), c => c.charCodeAt(0)))
      })

      // Send input to server
      this.term.onData((data) => {
        this.pushEvent("terminal_input", { data: btoa(data) })
      })

      // Handle window resize — debounce to avoid flooding
      this._resizeTimeout = null
      this.resizeObserver = new ResizeObserver(() => {
        clearTimeout(this._resizeTimeout)
        this._resizeTimeout = setTimeout(() => {
          this.fitAddon.fit()
          this.pushEvent("terminal_resize", { cols: this.term.cols, rows: this.term.rows })
        }, 100)
      })
      this.resizeObserver.observe(this.el)
    },

    destroyed() {
      this.resizeObserver?.disconnect()
      this.term?.dispose()
    }
  },

  ScrollBottom: {
    mounted() {
      this.stickToBottom = true;
      this.handleScroll = () => {
        const distanceFromBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight;
        this.stickToBottom = distanceFromBottom < 48;
      };
      this.el.addEventListener("scroll", this.handleScroll);
      this.scrollToBottom(true);
      this.observer = new MutationObserver(() => this.scrollToBottom(false));
      this.observer.observe(this.el, { childList: true, subtree: true });
    },
    updated() {
      this.scrollToBottom(false);
    },
    destroyed() {
      if (this.observer) this.observer.disconnect();
      if (this.handleScroll) this.el.removeEventListener("scroll", this.handleScroll);
    },
    scrollToBottom(force) {
      if (force || this.stickToBottom) {
        this.el.scrollTop = this.el.scrollHeight;
      }
    }
  },

  MentionContent: {
    mounted() {
      this.profiles = parseAgentProfiles(this.el.dataset.agentProfiles)
      this.decorate()

      this.handleMouseOver = (event) => {
        const mention = event.target.closest(".ui-mention[data-agent-name]")
        if (!mention || !this.el.contains(mention)) return

        const profile = this.profiles[mention.dataset.agentName]
        if (profile) MentionProfileCard.show(mention, profile, false)
      }

      this.handleMouseOut = (event) => {
        const mention = event.target.closest(".ui-mention[data-agent-name]")
        if (!mention || !this.el.contains(mention)) return
        if (mention.contains(event.relatedTarget)) return
        MentionProfileCard.scheduleHide()
      }

      this.handleClick = (event) => {
        // Image lightbox
        const img = event.target.closest(".ui-markdown img")
        if (img && this.el.contains(img)) {
          event.preventDefault()
          ImageLightbox.show(img.src)
          return
        }

        const mention = event.target.closest(".ui-mention[data-agent-name]")
        if (!mention || !this.el.contains(mention)) return

        event.preventDefault()
        const profile = this.profiles[mention.dataset.agentName]
        if (profile) MentionProfileCard.show(mention, profile, true)
      }

      this.el.addEventListener("mouseover", this.handleMouseOver)
      this.el.addEventListener("mouseout", this.handleMouseOut)
      this.el.addEventListener("click", this.handleClick)
    },
    updated() {
      this.profiles = parseAgentProfiles(this.el.dataset.agentProfiles)
      this.decorate()
    },
    destroyed() {
      this.el.removeEventListener("mouseover", this.handleMouseOver)
      this.el.removeEventListener("mouseout", this.handleMouseOut)
      this.el.removeEventListener("click", this.handleClick)
    },
    decorate() {
      enhanceMentionsInElement(this.el, this.profiles)
    }
  },

  ChatComposer: {
    mounted() {
      this.textarea = this.el.querySelector("#chat-composer")
      this.overlay = this.el.querySelector('[data-role="mention-overlay"]')
      this.menu = this.el.querySelector('[data-role="mention-menu"]')
      this.profiles = parseAgentProfiles(this.el.dataset.agentProfiles)
      this.agentNames = Object.keys(this.profiles).sort((left, right) => left.localeCompare(right))
      this.selectedIndex = 0

      this.resize = () => {
        this.textarea.style.height = "auto"
        this.textarea.style.height = `${Math.min(this.textarea.scrollHeight, 192)}px`
      }

      this.syncOverlay = () => {
        this.overlay.innerHTML = renderMentionMarkup(this.textarea.value, this.profiles)
        this.overlay.scrollTop = this.textarea.scrollTop
        this.overlay.scrollLeft = this.textarea.scrollLeft
      }

      this.activeMention = () => {
        const cursor = this.textarea.selectionStart
        const beforeCursor = this.textarea.value.slice(0, cursor)
        const match = beforeCursor.match(/(^|[\s(])@([A-Za-z0-9_-]*)$/)

        if (!match) return null

        return {
          query: match[2],
          start: cursor - match[2].length - 1,
          end: cursor
        }
      }

      this.renderMenu = () => {
        const mention = this.activeMention()

        if (!mention) {
          this.menu.classList.add("hidden")
          this.menu.innerHTML = ""
          return
        }

        const query = mention.query.toLowerCase()
        const matches = this.agentNames.filter((name) => name.toLowerCase().startsWith(query)).slice(0, 6)

        if (matches.length === 0) {
          this.menu.classList.remove("hidden")
          this.menu.innerHTML = '<div class="ui-mention-menu__empty">No matching agents</div>'
          return
        }

        this.selectedIndex = Math.min(this.selectedIndex, matches.length - 1)

        this.menu.classList.remove("hidden")
        this.menu.innerHTML = matches.map((name, index) => {
          const profile = this.profiles[name]
          const description = profile.description?.trim() || profile.personality?.trim() || "No details"

          return `
            <button
              type="button"
              class="ui-mention-menu__item${index === this.selectedIndex ? " is-active" : ""}"
              data-agent-name="${escapeHtml(name)}"
            >
              <span class="ui-mention-menu__name">@${escapeHtml(name)}</span>
              <span class="ui-mention-menu__description">${escapeHtml(description)}</span>
            </button>
          `
        }).join("")
      }

      this.applyMention = (agentName) => {
        const mention = this.activeMention()
        if (!mention) return

        const nextValue = `${this.textarea.value.slice(0, mention.start)}@${agentName} ${this.textarea.value.slice(mention.end)}`
        const nextCursor = mention.start + agentName.length + 2

        this.textarea.value = nextValue
        this.textarea.setSelectionRange(nextCursor, nextCursor)
        this.menu.classList.add("hidden")
        this.selectedIndex = 0
        this.resize()
        this.syncOverlay()
        this.textarea.dispatchEvent(new Event("input", {bubbles: true}))
      }

      this.handleKeydown = (event) => {
        const items = Array.from(this.menu.querySelectorAll("[data-agent-name]"))
        const menuOpen = !this.menu.classList.contains("hidden") && items.length > 0

        if (menuOpen && event.key === "ArrowDown") {
          event.preventDefault()
          this.selectedIndex = (this.selectedIndex + 1) % items.length
          this.renderMenu()
          return
        }

        if (menuOpen && event.key === "ArrowUp") {
          event.preventDefault()
          this.selectedIndex = (this.selectedIndex - 1 + items.length) % items.length
          this.renderMenu()
          return
        }

        if (menuOpen && (event.key === "Enter" || event.key === "Tab")) {
          event.preventDefault()
          this.applyMention(items[this.selectedIndex].dataset.agentName)
          return
        }

        if (event.key === "Escape") {
          this.menu.classList.add("hidden")
          return
        }

        if (event.key === "Enter" && !event.shiftKey) {
          event.preventDefault()
          const form = this.textarea.form
          if (form) form.requestSubmit()
        }
      }

      this.handleInput = () => {
        this.resize()
        this.syncOverlay()
        this.renderMenu()
      }

      this.handleScroll = () => {
        this.overlay.scrollTop = this.textarea.scrollTop
        this.overlay.scrollLeft = this.textarea.scrollLeft
      }

      this.handleMenuClick = (event) => {
        const item = event.target.closest("[data-agent-name]")
        if (!item) return

        event.preventDefault()
        this.applyMention(item.dataset.agentName)
        this.textarea.focus()
      }

      this.textarea.addEventListener("input", this.handleInput)
      this.textarea.addEventListener("keydown", this.handleKeydown)
      this.textarea.addEventListener("scroll", this.handleScroll)
      this.textarea.addEventListener("click", this.renderMenu)
      this.textarea.addEventListener("keyup", this.renderMenu)
      this.menu.addEventListener("mousedown", this.handleMenuClick)

      this.resize()
      this.syncOverlay()
      this.renderMenu()
    },
    updated() {
      this.profiles = parseAgentProfiles(this.el.dataset.agentProfiles)
      this.agentNames = Object.keys(this.profiles).sort((left, right) => left.localeCompare(right))
      this.resize()
      this.syncOverlay()
      this.renderMenu()
    },
    destroyed() {
      this.textarea.removeEventListener("input", this.handleInput)
      this.textarea.removeEventListener("keydown", this.handleKeydown)
      this.textarea.removeEventListener("scroll", this.handleScroll)
      this.textarea.removeEventListener("click", this.renderMenu)
      this.textarea.removeEventListener("keyup", this.renderMenu)
      this.menu.removeEventListener("mousedown", this.handleMenuClick)
    }
  }
};

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

