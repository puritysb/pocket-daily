// Bridge between the app and foliate-js. The app serves this directory and the
// open book from its own URL scheme; nothing here touches the network.
import './foliate-js/view.js'
import { EPUB } from './foliate-js/epub.js'
import * as XPointer from './xpointer.js'

const post = message => {
    try { globalThis.webkit?.messageHandlers?.pocket?.postMessage(message) }
    catch (e) { console.error(e) }
}

const fail = (stage, error) => post({ type: 'error', stage, message: String(error?.message ?? error) })
addEventListener('error', e => fail('script', e.error ?? e.message))
addEventListener('unhandledrejection', e => fail('promise', e.reason))

// Web Crypto is unavailable outside secure contexts; font deobfuscation only
// needs SHA-1 of the package identifier.
const sha1 = async data => {
    if (globalThis.crypto?.subtle && globalThis.isSecureContext)
        return new Uint8Array(await crypto.subtle.digest('SHA-1', data))
    const bytes = new Uint8Array(data)
    const words = new Uint32Array(80)
    const length = bytes.length
    const padded = new Uint8Array(((length + 9 + 63) >> 6) << 6)
    padded.set(bytes)
    padded[length] = 0x80
    const view = new DataView(padded.buffer)
    view.setUint32(padded.length - 4, length * 8 >>> 0)
    view.setUint32(padded.length - 8, Math.floor(length / 0x20000000))
    let [a0, b0, c0, d0, e0] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0]
    const rotl = (x, n) => (x << n) | (x >>> (32 - n))
    for (let block = 0; block < padded.length; block += 64) {
        for (let i = 0; i < 16; i++) words[i] = view.getUint32(block + i * 4)
        for (let i = 16; i < 80; i++) words[i] = rotl(words[i - 3] ^ words[i - 8] ^ words[i - 14] ^ words[i - 16], 1)
        let [a, b, c, d, e] = [a0, b0, c0, d0, e0]
        for (let i = 0; i < 80; i++) {
            const [f, k] = i < 20 ? [(b & c) | (~b & d), 0x5a827999]
                : i < 40 ? [b ^ c ^ d, 0x6ed9eba1]
                : i < 60 ? [(b & c) | (b & d) | (c & d), 0x8f1bbcdc]
                : [b ^ c ^ d, 0xca62c1d6]
            const t = (rotl(a, 5) + f + e + k + words[i]) >>> 0
            e = d; d = c; c = rotl(b, 30) >>> 0; b = a; a = t
        }
        a0 = (a0 + a) >>> 0; b0 = (b0 + b) >>> 0; c0 = (c0 + c) >>> 0
        d0 = (d0 + d) >>> 0; e0 = (e0 + e) >>> 0
    }
    const out = new DataView(new ArrayBuffer(20))
    ;[a0, b0, c0, d0, e0].forEach((v, i) => out.setUint32(i * 4, v))
    return new Uint8Array(out.buffer)
}

const makeZipLoader = async blob => {
    const { configure, ZipReader, BlobReader, TextWriter, BlobWriter } = await import('./foliate-js/vendor/zip.js')
    configure({ useWebWorkers: false })
    const reader = new ZipReader(new BlobReader(blob))
    const entries = await reader.getEntries()
    const map = new Map(entries.map(entry => [entry.filename, entry]))
    const load = f => (name, ...args) => map.has(name) ? f(map.get(name), ...args) : null
    return {
        loadText: load(entry => entry.getData(new TextWriter())),
        loadBlob: load((entry, type) => entry.getData(new BlobWriter(type))),
        getSize: name => map.get(name)?.uncompressedSize ?? 0,
        sha1,
    }
}

const text = value => {
    if (!value) return ''
    if (typeof value === 'string') return value
    if (Array.isArray(value)) return value.map(text).filter(Boolean).join(', ')
    if (value.name) return text(value.name)
    return Object.values(value)[0] ?? ''
}

const flattenTOC = (items, depth = 0, out = []) => {
    for (const item of items ?? []) {
        out.push({ label: String(item.label ?? '').trim(), href: item.href ?? '', depth })
        flattenTOC(item.subitems, depth + 1, out)
    }
    return out
}

const themes = {
    paper: { background: '#f4f1ea', foreground: '#1b1b1b', link: '#1b1b1b' },
    white: { background: '#ffffff', foreground: '#000000', link: '#000000' },
    night: { background: '#111111', foreground: '#d6d6d6', link: '#d6d6d6' },
}
const families = {
    serif: `'New York', ui-serif, 'AppleMyungjo', 'Hiragino Mincho ProN', serif`,
    sans: `-apple-system, system-ui, 'Apple SD Gothic Neo', 'Hiragino Sans', sans-serif`,
}

const bookCSS = a => {
    const theme = themes[a.theme] ?? themes.paper
    const family = families[a.fontFamily]
    return `
    @namespace epub "http://www.idpf.org/2007/ops";
    html { color-scheme: ${a.theme === 'night' ? 'dark' : 'light'}; font-size: ${a.fontScale}% !important; }
    html, body { background: ${theme.background} !important; color: ${theme.foreground} !important; }
    body * { color: inherit !important; background-color: transparent !important; }
    a:link, a:visited { color: ${theme.link} !important; text-decoration: underline; }
    ${family ? `body, body :not(code):not(pre):not(kbd):not(samp) { font-family: ${family} !important; }` : ''}
    p, li, blockquote, dd {
        line-height: ${a.lineHeight} !important;
        text-align: ${a.justify ? 'justify' : 'start'};
        -webkit-hyphens: ${a.hyphenate ? 'auto' : 'manual'};
        hyphens: ${a.hyphenate ? 'auto' : 'manual'};
        widows: 2;
        orphans: 2;
    }
    [align="left"] { text-align: left; }
    [align="right"] { text-align: right; }
    [align="center"] { text-align: center; }
    pre { white-space: pre-wrap !important; }
    img, svg { max-width: 100%; height: auto; }
    ${a.theme === 'night' ? 'img { filter: brightness(0.85); }' : ''}
    aside[epub|type~="footnote"], aside[epub|type~="endnote"], aside[epub|type~="note"], aside[epub|type~="rearnote"] { display: none; }
    `
}

let view = null
let appearance = {
    theme: 'paper', fontScale: 100, lineHeight: 1.55, fontFamily: 'publisher',
    justify: true, hyphenate: true, margin: 28, gap: 6, maxInlineSize: 680, columns: 1,
    insetTop: 0, insetBottom: 0, tapZones: 'sides',
}

const applyAppearance = () => {
    const theme = themes[appearance.theme] ?? themes.paper
    const root = document.documentElement.style
    root.setProperty('--pd-background', theme.background)
    root.setProperty('--pd-inset-top', `${appearance.insetTop}px`)
    root.setProperty('--pd-inset-bottom', `${appearance.insetBottom}px`)
    const renderer = view?.renderer
    if (!renderer) return
    renderer.setAttribute('margin', `${appearance.margin}px`)
    renderer.setAttribute('gap', `${appearance.gap}%`)
    renderer.setAttribute('max-inline-size', `${appearance.maxInlineSize}px`)
    renderer.setAttribute('max-column-count', String(appearance.columns))
    renderer.removeAttribute('animated')
    renderer.setStyles?.(bookCSS(appearance))
}

// foliate reports progress at the end of the visible page, and NaN for a
// section that fits on one page. Sync needs the start of the page, like
// KOReader, so it is derived from the renderer's own section position.
const startFraction = ({ index, fraction }) => {
    const fractions = view.getSectionFractions()
    const from = fractions[index] ?? 0
    const to = fractions[index + 1] ?? from
    const within = Number.isFinite(fraction) ? Math.min(Math.max(fraction, 0), 1) : 0
    const value = from + within * (to - from)
    return Number.isFinite(value) ? Math.min(Math.max(value, 0), 1) : 0
}

const locationMessage = rendered => {
    const location = view.lastLocation ?? {}
    const range = rendered.range ?? location.range
    const sectionIndex = rendered.index
    let xpointer = null
    const doc = range?.startContainer?.ownerDocument
    if (doc && typeof sectionIndex === 'number') {
        try { xpointer = XPointer.fromRange(doc, range, sectionIndex) }
        catch (e) { console.error(e) }
    }
    return {
        type: 'relocate',
        fraction: startFraction(rendered),
        cfi: location.cfi ?? null,
        xpointer,
        sectionIndex: sectionIndex ?? null,
        chapter: location.tocItem?.label ?? null,
        location: location.location ? { current: location.location.current, total: location.location.total } : null,
    }
}

const tap = (doc, event) => {
    if (event.defaultPrevented || event.target.closest?.('a[href]')) return
    const selection = doc.defaultView.getSelection()
    if (selection && !selection.isCollapsed) return
    const frame = doc.defaultView.frameElement
    const x = (frame?.getBoundingClientRect().left ?? 0) + event.clientX
    const width = innerWidth || 1
    const zone = x < width * 0.3 ? 'left' : x > width * 0.7 ? 'right' : 'center'
    if (zone === 'center') post({ type: 'tap' })
    else if (zone === 'left') view.goLeft()
    else view.goRight()
}

const keydown = event => {
    if (event.metaKey || event.ctrlKey || event.altKey) return
    switch (event.key) {
        case 'ArrowRight': case 'PageDown': case ' ': case 'ArrowDown':
            event.preventDefault()
            if (event.key === 'ArrowRight') view?.goRight(); else view?.next()
            break
        case 'ArrowLeft': case 'PageUp': case 'ArrowUp':
            event.preventDefault()
            if (event.key === 'ArrowLeft') view?.goLeft(); else view?.prev()
            break
        case 'Escape':
            post({ type: 'escape' })
            break
    }
}
addEventListener('keydown', keydown)

const navigate = async target => {
    if (!view) return false
    if (target?.xpointer) {
        const parsed = XPointer.parse(target.xpointer)
        if (parsed && parsed.sectionIndex < view.book.sections.length) {
            let exact = true
            await view.renderer.goTo({
                index: parsed.sectionIndex,
                anchor: doc => {
                    const resolved = XPointer.toRange(doc, parsed)
                    exact = resolved.exact
                    return resolved.range
                },
            })
            return exact || typeof target.fraction !== 'number' ? true : navigate({ fraction: target.fraction })
        }
    }
    if (target?.cfi) {
        const resolved = await view.goTo(target.cfi)
        if (resolved) return true
    }
    if (typeof target?.fraction === 'number' && Number.isFinite(target.fraction)) {
        await view.goToFraction(Math.min(Math.max(target.fraction, 0), 1))
        return true
    }
    return false
}

globalThis.PocketReader = {
    async open({ url, location, appearance: initial }) {
        try {
            if (initial) appearance = { ...appearance, ...initial }
            const response = await fetch(url)
            if (!response.ok) throw new Error(`The book could not be loaded (${response.status}).`)
            const blob = await response.blob()
            const book = await new EPUB(await makeZipLoader(blob)).init()
            view?.close()
            view?.remove()
            view = document.createElement('foliate-view')
            document.body.append(view)
            // Registered after the view's own listener, so view.lastLocation is current.
            const listenRenderer = () => view.renderer.addEventListener('relocate', e => post(locationMessage(e.detail)))
            view.addEventListener('load', ({ detail: { doc } }) => {
                doc.addEventListener('click', e => tap(doc, e))
                doc.addEventListener('keydown', keydown)
            })
            view.addEventListener('external-link', e => {
                e.preventDefault()
                post({ type: 'external-link', href: e.detail.href_ })
            })
            await view.open(book)
            listenRenderer()
            applyAppearance()
            const metadata = book.metadata ?? {}
            post({
                type: 'opened',
                title: text(metadata.title),
                author: text(metadata.author),
                language: text(metadata.language),
                sections: book.sections.length,
                fixedLayout: view.isFixedLayout,
                toc: flattenTOC(book.toc),
            })
            if (!(await navigate(location))) await view.goToTextStart()
        } catch (e) {
            fail('open', e)
        }
    },
    setAppearance(next) {
        appearance = { ...appearance, ...next }
        applyAppearance()
    },
    next: () => view?.next(),
    prev: () => view?.prev(),
    goLeft: () => view?.goLeft(),
    goRight: () => view?.goRight(),
    goTo: target => navigate(target),
    goToHref: href => view?.goTo(href),
}

applyAppearance()
post({ type: 'ready' })
