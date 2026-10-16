<script lang="ts">
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { onMount } from "svelte";

  type Connection = {
    client_id: string;
    name: string;
    platform: string;
    addr: string;
    rtt_ms: number | null;
  };

  type PairedDevice = {
    client_id: string;
    name: string;
    platform: string;
    paired_at: number;
    last_seen: number;
  };

  type HostStatus = {
    host_name: string;
    host_id: string;
    port: number;
    pairing_pin: string | null;
    pairing_secs_left: number | null;
    connections: Connection[];
    devices: PairedDevice[];
  };

  let status = $state<HostStatus | null>(null);
  let secsLeft = $state(0);
  let busy = $state(false);
  let error = $state<string | null>(null);
  let editingName = $state(false);
  let draftName = $state("");

  async function refresh() {
    try {
      status = await invoke<HostStatus>("status");
      secsLeft = status.pairing_secs_left ?? 0;
      error = null;
    } catch (e) {
      error = String(e);
    }
  }

  async function run(action: () => Promise<unknown>) {
    busy = true;
    try {
      await action();
      await refresh();
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }

  const startPairing = () => run(() => invoke("start_pairing"));
  const stopPairing = () => run(() => invoke("stop_pairing"));
  const forget = (id: string) => run(() => invoke("forget_device", { clientId: id }));

  async function saveName() {
    const name = draftName.trim();
    editingName = false;
    if (!name || name === status?.host_name) return;
    await run(() => invoke("set_host_name", { name }));
  }

  onMount(() => {
    refresh();

    // Hitung mundur lokal supaya PIN terlihat kedaluwarsa tepat waktu tanpa
    // polling host tiap detik.
    const tick = setInterval(() => {
      if (secsLeft > 0) {
        secsLeft -= 1;
        if (secsLeft === 0) refresh();
      }
    }, 1000);

    // Host menyiarkan perubahan; refresh hanya saat ada kabar, bukan polling.
    const unlisten = listen("decky://event", refresh);

    return () => {
      clearInterval(tick);
      unlisten.then((fn) => fn());
    };
  });

  const relative = (unixSecs: number) => {
    const mins = Math.floor((Date.now() / 1000 - unixSecs) / 60);
    if (mins < 1) return "baru saja";
    if (mins < 60) return `${mins} menit lalu`;
    const hours = Math.floor(mins / 60);
    if (hours < 24) return `${hours} jam lalu`;
    return `${Math.floor(hours / 24)} hari lalu`;
  };

  const isOnline = (id: string) =>
    status?.connections.some((c) => c.client_id === id) ?? false;

  // `autofocus` ditandai masalah aksesibilitas oleh Svelte, tapi di sini
  // fokus memang yang diinginkan: input baru muncul karena user mengkliknya.
  const focusNow = (node: HTMLInputElement) => {
    node.focus();
    node.select();
  };
</script>

<main>
  <header>
    <div>
      <h1>Decky Host</h1>
      {#if status}
        {#if editingName}
          <input
            class="name-edit"
            bind:value={draftName}
            onblur={saveName}
            onkeydown={(e) => e.key === "Enter" && saveName()}
            use:focusNow
          />
        {:else}
          <button
            class="name"
            onclick={() => {
              draftName = status!.host_name;
              editingName = true;
            }}
          >
            {status.host_name} <span class="port">:{status.port}</span>
          </button>
        {/if}
      {/if}
    </div>
    <span class="badge" class:live={status && status.connections.length > 0}>
      {status?.connections.length ?? 0} terhubung
    </span>
  </header>

  {#if error}
    <p class="error">{error}</p>
  {/if}

  <section class="pairing">
    {#if status?.pairing_pin}
      <p class="label">Masukkan PIN ini di HP</p>
      <p class="pin">{status.pairing_pin}</p>
      <p class="countdown" class:urgent={secsLeft <= 10}>
        Berlaku {secsLeft} detik lagi
      </p>
      <button onclick={stopPairing} disabled={busy}>Batalkan</button>
    {:else}
      <p class="label">Tambahkan HP baru</p>
      <button class="primary" onclick={startPairing} disabled={busy}>
        Mulai pairing
      </button>
    {/if}
  </section>

  <section>
    <h2>Device</h2>
    {#if !status || status.devices.length === 0}
      <p class="empty">Belum ada device. Mulai pairing untuk menambahkan.</p>
    {:else}
      <ul>
        {#each status.devices as device (device.client_id)}
          {@const conn = status.connections.find((c) => c.client_id === device.client_id)}
          <li>
            <span class="dot" class:online={isOnline(device.client_id)}></span>
            <div class="info">
              <strong>{device.name}</strong>
              <small>
                {#if conn}
                  {conn.addr}{conn.rtt_ms !== null ? ` · ${conn.rtt_ms} ms` : ""}
                {:else}
                  Terakhir terlihat {relative(device.last_seen)}
                {/if}
              </small>
            </div>
            <button class="ghost" onclick={() => forget(device.client_id)} disabled={busy}>
              Lupakan
            </button>
          </li>
        {/each}
      </ul>
    {/if}
  </section>
</main>

<style>
  :global(:root) {
    --bg: #ffffff;
    --fg: #16181d;
    --muted: #6b7280;
    --line: #e5e7eb;
    --accent: #2f6fed;
    --ok: #16a34a;
    --danger: #dc2626;
  }

  @media (prefers-color-scheme: dark) {
    :global(:root) {
      --bg: #15171c;
      --fg: #e8eaed;
      --muted: #9aa0a6;
      --line: #2a2e36;
      --accent: #6d9cff;
    }
  }

  :global(body) {
    margin: 0;
    background: var(--bg);
    color: var(--fg);
    font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
  }

  main {
    max-width: 560px;
    margin: 0 auto;
    padding: 24px 20px 40px;
  }

  header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 16px;
    margin-bottom: 24px;
  }

  h1 {
    margin: 0;
    font-size: 20px;
    letter-spacing: -0.01em;
  }

  h2 {
    margin: 0 0 12px;
    font-size: 13px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--muted);
  }

  .name,
  .name-edit {
    margin-top: 2px;
    padding: 2px 4px;
    font-size: 13px;
    color: var(--muted);
    background: none;
    border: 1px solid transparent;
    border-radius: 6px;
    cursor: text;
  }

  .name:hover {
    border-color: var(--line);
  }

  .name-edit {
    color: var(--fg);
    border-color: var(--accent);
    outline: none;
  }

  .port {
    opacity: 0.6;
  }

  .badge {
    flex-shrink: 0;
    padding: 4px 10px;
    font-size: 12px;
    color: var(--muted);
    border: 1px solid var(--line);
    border-radius: 999px;
  }

  .badge.live {
    color: var(--ok);
    border-color: color-mix(in srgb, var(--ok) 40%, transparent);
  }

  section {
    margin-bottom: 28px;
  }

  .pairing {
    padding: 24px;
    text-align: center;
    border: 1px solid var(--line);
    border-radius: 12px;
  }

  .label {
    margin: 0 0 12px;
    font-size: 13px;
    color: var(--muted);
  }

  .pin {
    margin: 0;
    font-size: 44px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    letter-spacing: 0.14em;
  }

  .countdown {
    margin: 4px 0 16px;
    font-size: 13px;
    color: var(--muted);
  }

  .countdown.urgent {
    color: var(--danger);
  }

  button {
    padding: 8px 16px;
    font: inherit;
    font-size: 14px;
    color: var(--fg);
    background: none;
    border: 1px solid var(--line);
    border-radius: 8px;
    cursor: pointer;
  }

  button:hover:not(:disabled) {
    border-color: var(--accent);
  }

  button:disabled {
    opacity: 0.5;
    cursor: default;
  }

  button.primary {
    color: #fff;
    background: var(--accent);
    border-color: var(--accent);
  }

  button.ghost {
    font-size: 13px;
    color: var(--muted);
    border-color: transparent;
  }

  button.ghost:hover:not(:disabled) {
    color: var(--danger);
    border-color: color-mix(in srgb, var(--danger) 40%, transparent);
  }

  ul {
    margin: 0;
    padding: 0;
    list-style: none;
  }

  li {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 12px 0;
    border-bottom: 1px solid var(--line);
  }

  li:last-child {
    border-bottom: none;
  }

  .dot {
    width: 8px;
    height: 8px;
    flex-shrink: 0;
    background: var(--line);
    border-radius: 50%;
  }

  .dot.online {
    background: var(--ok);
  }

  .info {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-width: 0;
  }

  .info small {
    font-size: 12px;
    color: var(--muted);
  }

  .empty {
    margin: 0;
    font-size: 14px;
    color: var(--muted);
  }

  .error {
    padding: 10px 12px;
    font-size: 13px;
    color: var(--danger);
    border: 1px solid color-mix(in srgb, var(--danger) 35%, transparent);
    border-radius: 8px;
  }
</style>
