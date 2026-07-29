// Opt into the scroll-reveal styles, before first paint.
//
// Two things make this its own blocking file in the head rather than a line inside site.js.
// It has to run before paint, or every revealed section flashes in; and it has to be
// external, because the alternative is an inline script, which means either
// `script-src 'unsafe-inline'` in the CSP or a hash in vercel.json that goes stale the
// first time someone edits this line and says nothing when it does.
//
// The condition is the safety property: everything marked `.reveal` is plain markup, and
// the hidden state is scoped to `.js`. If this file never loads, or IntersectionObserver
// is missing, the sections are simply visible rather than transparent forever.
if ('IntersectionObserver' in window) {
    document.documentElement.classList.add('js');
}
