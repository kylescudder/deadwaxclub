// Public list viewer. Fetches the unauthenticated `get_shared_list` and
// `get_shared_list_records` Postgres RPCs from Supabase using the project's
// anon key (which is safe to ship in the browser — RLS still applies).

const config = window.DEADWAXCLUB_CONFIG ?? {};
const main = document.getElementById("main");

const token = location.pathname.split("/").filter(Boolean).pop();

async function rpc(name, params) {
    const url = `${config.supabaseUrl}/rest/v1/rpc/${name}`;
    const res = await fetch(url, {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            apikey: config.supabaseAnonKey,
            Authorization: `Bearer ${config.supabaseAnonKey}`,
        },
        body: JSON.stringify(params),
    });
    if (!res.ok) {
        throw new Error(`Supabase RPC ${name} returned ${res.status}`);
    }
    return res.json();
}

function escape(s) {
    return String(s ?? "").replace(/[&<>"']/g, (c) => ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
    })[c]);
}

function coverURL(record) {
    if (record.cover_art_storage_path) {
        return `${config.supabaseUrl}/storage/v1/object/public/covers/${record.cover_art_storage_path}`;
    }
    return record.cover_art_source_url || null;
}

function renderError(message) {
    main.innerHTML = `
        <div class="state">
            <div class="state-icon">
                <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/>
                    <line x1="12" y1="9" x2="12" y2="13"/>
                    <line x1="12" y1="17" x2="12" y2="17"/>
                </svg>
            </div>
            <h2>Couldn't load list</h2>
            <p>${escape(message)}</p>
        </div>
    `;
}

function renderList(info, records) {
    const owner = info.owner_display_name
        ? `Shared by ${escape(info.owner_display_name)}`
        : "";
    const description = info.description
        ? `<p class="list-copy">${escape(info.description)}</p>`
        : "";
    const tiles = records
        .map((r) => {
            const cover = coverURL(r);
            const coverHTML = cover
                ? `<img src="${escape(cover)}" alt="${escape(r.title)}" loading="lazy" />`
                : `<svg width="40" height="40" viewBox="0 0 24 24" fill="currentColor"><path d="M12 2a10 10 0 100 20 10 10 0 000-20zm0 14a4 4 0 110-8 4 4 0 010 8zm0-2.5a1.5 1.5 0 100-3 1.5 1.5 0 000 3z"/></svg>`;
            const colour = r.colourway
                ? `<p class="colour">${escape(r.colourway)}</p>`
                : "";
            return `
                <div class="record-tile">
                    <div class="cover">${coverHTML}</div>
                    <div class="meta">
                        <p class="title">${escape(r.title)}</p>
                        <p class="artist">${escape(r.artist)}${r.year ? ` · ${r.year}` : ""}</p>
                        ${colour}
                    </div>
                </div>
            `;
        })
        .join("");

    main.innerHTML = `
        <section class="list-hero">
            <p class="list-kicker">${owner ? owner : "Shared list"}</p>
            <div class="list-title-row">
                <h1>${escape(info.name)}</h1>
                <span class="record-count">${records.length} record${records.length === 1 ? "" : "s"}</span>
            </div>
            ${description}
            <div class="button-row list-actions">
                <a class="button button-primary" href="deadwaxclub://list/${encodeURIComponent(token)}">Open in Deadwax Club</a>
                <a class="button button-secondary" href="/">Get the app</a>
            </div>
        </section>

        ${
            records.length === 0
                ? `<div class="state"><h2>Empty list</h2><p>The owner hasn't added any records yet.</p></div>`
                : `<section class="records">${tiles}</section>`
        }
    `;
}

async function load() {
    if (!config.supabaseUrl || !config.supabaseAnonKey) {
        renderError("This site isn't configured. Copy web/js/config.example.js to web/js/config.js and fill in your Supabase URL + anon key.");
        return;
    }
    if (!token) {
        renderError("No list token in URL.");
        return;
    }
    try {
        const [infoRows, records] = await Promise.all([
            rpc("get_shared_list", { token }),
            rpc("get_shared_list_records", { token }),
        ]);
        const info = Array.isArray(infoRows) ? infoRows[0] : infoRows;
        if (!info) {
            renderError("This list isn't available — the owner may have made it private or deleted it.");
            return;
        }
        document.title = `${info.name} · Deadwax Club`;
        renderList(info, Array.isArray(records) ? records : []);
    } catch (err) {
        renderError(err.message ?? String(err));
    }
}

load();
