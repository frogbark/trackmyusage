// trackmyusage.dev — the page's behaviour. Loaded with `defer`, so it runs after the
// document is parsed and blocks nothing. Everything here is progressive: with this file
// missing the page still reads, the layouts still show the default one, and the install
// command is still selectable by hand.

// ---------------------------------------------------------------- Providers

// The matrix is rendered from providers.json, which is generated from ProviderRegistry and
// checked in CI. A hand-written table here would go stale the first time an adapter landed,
// and a page overstating coverage is exactly what this project argues against.
fetch('providers.json')
    .then(function (response) {
        return response.json();
    })
    .then(function (data) {
        var order = { built: 0, blocked: 1, planned: 2 };

        // Built with DOM calls rather than innerHTML. The data is generated from
        // ProviderRegistry and not user input, but an adapter's note is free text written
        // in Swift, and there is no reason for the one place it reaches a browser to be the
        // one place a stray angle bracket becomes markup.
        function el(tag, className, text) {
            var node = document.createElement(tag);
            if (className) node.className = className;
            if (text !== undefined) node.textContent = text;
            return node;
        }

        var counts = document.getElementById('counts');
        counts.textContent = '';
        ['built', 'blocked', 'planned'].forEach(function (status) {
            var key = el('span', 'key');
            key.appendChild(el('span', 'dot ' + status));
            key.appendChild(el('span', 'n', data[status]));
            key.appendChild(document.createTextNode(' ' + status));
            counts.appendChild(key);
        });

        var total = el('span', 'key');
        total.appendChild(document.createTextNode('of '));
        total.appendChild(el('span', 'n', data.total));
        total.appendChild(document.createTextNode(' intended'));
        counts.appendChild(total);

        // Sorted by status so the built ones lead. The JSON's own order is registry order,
        // which is meaningful in the code and arbitrary on a page.
        var providers = data.providers.slice().sort(function (a, b) {
            return order[a.status] - order[b.status] || a.id.localeCompare(b.id);
        });

        var matrix = document.getElementById('matrix');
        matrix.textContent = '';
        providers.forEach(function (provider) {
            var row = el('div', 'provider ' + provider.status);
            row.appendChild(el('span', 'dot ' + provider.status));
            row.appendChild(el('span', 'name', provider.id));
            if (provider.note) row.appendChild(el('span', 'note', provider.note));
            matrix.appendChild(row);
        });
    })
    .catch(function () {
        document.getElementById('counts').textContent =
            'Provider list unavailable — see the repository.';
    });

// ---------------------------------------------------------------- Layout switcher

(function () {
    var tabs = Array.prototype.slice.call(document.querySelectorAll('[role="tab"]'));
    if (!tabs.length) return;

    function select(tab) {
        tabs.forEach(function (candidate) {
            var on = candidate === tab;
            candidate.setAttribute('aria-selected', on ? 'true' : 'false');
            document.getElementById(candidate.getAttribute('aria-controls')).hidden = !on;
        });
    }

    tabs.forEach(function (tab, index) {
        tab.addEventListener('click', function () {
            select(tab);
        });

        // Arrow-key movement is what makes a tablist a tablist rather than a row of buttons
        // wearing the role.
        tab.addEventListener('keydown', function (event) {
            var next =
                event.key === 'ArrowRight' ? index + 1 : event.key === 'ArrowLeft' ? index - 1 : -1;
            if (next < 0 && event.key !== 'ArrowLeft') return;
            event.preventDefault();
            var target = tabs[(next + tabs.length) % tabs.length];
            select(target);
            target.focus();
        });
    });
})();

// ---------------------------------------------------------------- Copy button

// Falls back to leaving the text selectable, which is why the command is also wrapped in
// `user-select: all`.
document.querySelectorAll('.copy').forEach(function (button) {
    button.addEventListener('click', function () {
        var text = document.getElementById(button.dataset.copy).textContent;
        navigator.clipboard.writeText(text).then(function () {
            button.textContent = 'Copied';
            button.classList.add('done');
            setTimeout(function () {
                button.textContent = 'Copy';
                button.classList.remove('done');
            }, 1600);
        });
    });
});

// ---------------------------------------------------------------- Nav hairline and reveal

(function () {
    var nav = document.getElementById('nav');
    if (nav) {
        var onScroll = function () {
            nav.classList.toggle('scrolled', window.scrollY > 8);
        };
        onScroll();
        window.addEventListener('scroll', onScroll, { passive: true });
    }

    // boot.js only adds `.js` when this exists, so the hidden state is never applied
    // without something here to take it back off.
    if (!('IntersectionObserver' in window)) return;

    var observer = new IntersectionObserver(
        function (entries) {
            entries.forEach(function (entry) {
                if (!entry.isIntersecting) return;
                entry.target.classList.add('in');
                observer.unobserve(entry.target);
            });
        },
        { rootMargin: '0px 0px -8% 0px' }
    );

    document.querySelectorAll('.reveal').forEach(function (element) {
        observer.observe(element);
    });
})();
