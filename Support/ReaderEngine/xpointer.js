// KOReader (crengine) XPointers for a section document, the position format
// shared with X3/X4 firmware and KOReader sync:
//   /body/DocFragment[N]/body/div[2]/p[5]/text()[1].40
// N is the 1-based spine index. Element steps count same-name siblings and
// omit the index when there is only one; text steps skip whitespace-only
// nodes the same way. The final offset counts Unicode code points.

const isTextStep = node => node.nodeType === Node.TEXT_NODE || node.nodeType === Node.CDATA_SECTION_NODE
const hasContent = node => isTextStep(node) && /\S/.test(node.data)
const nameOf = element => element.localName.toLowerCase()

const codePointLength = (text, end = text.length) => {
    let count = 0
    for (let i = 0; i < end; i++) {
        const unit = text.charCodeAt(i)
        if (unit >= 0xd800 && unit <= 0xdbff && i + 1 < end) {
            const next = text.charCodeAt(i + 1)
            if (next >= 0xdc00 && next <= 0xdfff) i++
        }
        count++
    }
    return count
}

const utf16Offset = (text, codePoints) => {
    let index = 0
    for (let seen = 0; seen < codePoints && index < text.length; seen++) {
        const unit = text.charCodeAt(index)
        index += unit >= 0xd800 && unit <= 0xdbff && index + 1 < text.length
            && text.charCodeAt(index + 1) >= 0xdc00 && text.charCodeAt(index + 1) <= 0xdfff ? 2 : 1
    }
    return index
}

const nextNode = (node, root) => {
    if (node.firstChild) return node.firstChild
    while (node && node !== root) {
        if (node.nextSibling) return node.nextSibling
        node = node.parentNode
    }
    return null
}

// The first text node with content at or after a DOM boundary point, and the
// offset inside it. Falls back to the containing element.
const textPoint = (container, offset, root) => {
    if (hasContent(container)) return { node: container, offset }
    let node
    if (isTextStep(container)) node = nextNode(container, root)
    else if (offset < container.childNodes.length) node = container.childNodes[offset]
    else {
        node = container
        while (node && node !== root && !node.nextSibling) node = node.parentNode
        node = node && node !== root ? node.nextSibling : null
    }
    for (; node; node = nextNode(node, root)) {
        if (!root.contains(node)) break
        if (hasContent(node)) return { node, offset: 0 }
    }
    return { node: isTextStep(container) ? container.parentNode : container, offset: 0 }
}

const elementStep = element => {
    const name = nameOf(element)
    let index = 0, count = 0
    for (const sibling of element.parentNode.children) {
        if (nameOf(sibling) !== name) continue
        count++
        if (sibling === element) index = count
    }
    return count > 1 ? `/${name}[${index}]` : `/${name}`
}

const textStep = node => {
    let index = 0, count = 0
    for (const sibling of node.parentNode.childNodes) {
        if (!hasContent(sibling)) continue
        count++
        if (sibling === node) index = count
    }
    return count > 1 ? `/text()[${index}]` : '/text()'
}

export const fromRange = (doc, range, sectionIndex) => {
    const body = doc.body ?? doc.documentElement
    const base = `/body/DocFragment[${sectionIndex + 1}]/body`
    if (!range || !body.contains(range.startContainer)) return base
    const point = textPoint(range.startContainer, range.startOffset, body)
    let path = ''
    let element = point.node
    if (isTextStep(point.node)) {
        path = `${textStep(point.node)}.${codePointLength(point.node.data, point.offset)}`
        element = point.node.parentNode
    }
    for (; element && element !== body; element = element.parentNode) {
        if (element.nodeType !== Node.ELEMENT_NODE || !element.parentNode) return base
        path = elementStep(element) + path
    }
    return element === body ? base + path : base
}

const stepPattern = /^([A-Za-z_][\w.-]*|text\(\))(?:\[(\d+)\])?$/

export const parse = xpointer => {
    if (typeof xpointer !== 'string') return null
    const match = /^\/body\/DocFragment\[(\d+)\](?:\/body((?:\/[^/]+)*))?$/.exec(xpointer.trim())
    if (!match) return null
    const fragment = Number(match[1])
    if (!Number.isSafeInteger(fragment) || fragment < 1) return null
    const steps = []
    let offset = null
    const parts = (match[2] ?? '').split('/').filter(Boolean)
    for (const [i, raw] of parts.entries()) {
        let part = raw
        if (i === parts.length - 1) {
            const dot = /^(.*\))(?:\[(\d+)\])?\.(\d+)$|^(.*?)\.(\d+)$/.exec(part)
            if (dot) {
                part = dot[1] !== undefined ? dot[1] + (dot[2] ? `[${dot[2]}]` : '') : dot[4]
                offset = Number(dot[3] ?? dot[5])
            }
        }
        const step = stepPattern.exec(part)
        if (!step) return null
        const index = step[2] === undefined ? 1 : Number(step[2])
        if (!Number.isSafeInteger(index) || index < 1) return null
        steps.push({ name: step[1].toLowerCase(), index })
    }
    return { sectionIndex: fragment - 1, steps, offset }
}

// Resolves as deep as the document allows; a missing step keeps the nearest
// ancestor so a slightly different copy of the book still lands nearby.
export const toRange = (doc, parsed) => {
    const body = doc.body ?? doc.documentElement
    let node = body
    let exact = true
    for (const step of parsed.steps) {
        let found = null, count = 0
        if (step.name === 'text()') {
            for (const child of node.childNodes) {
                if (hasContent(child) && ++count === step.index) { found = child; break }
            }
        } else {
            for (const child of node.children) {
                if (nameOf(child) === step.name && ++count === step.index) { found = child; break }
            }
        }
        if (!found) { exact = false; break }
        node = found
    }
    const range = doc.createRange()
    if (isTextStep(node)) {
        const offset = utf16Offset(node.data, parsed.offset ?? 0)
        range.setStart(node, offset)
    } else {
        range.selectNodeContents(node)
    }
    range.collapse(true)
    return { range, exact }
}
