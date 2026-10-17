<script lang="ts">
  import { invoke } from "@tauri-apps/api/core";
  import { onMount } from "svelte";

  type Action =
    | { type: "none" }
    | { type: "launch_app"; path: string; args: string[] }
    | { type: "open_url"; url: string }
    | { type: "hotkey"; keys: string[] }
    | { type: "text"; text: string }
    | { type: "media_key"; key: string }
    | { type: "run_script"; command: string; args: string[] }
    | { type: "obs_scene"; scene: string };

  type ButtonDef = {
    idx: number;
    label: string;
    color?: string | null;
    icon_id?: string | null;
    style: "normal" | "toggle";
    action: Action;
  };

  type Profile = {
    id: string;
    name: string;
    cols: number;
    rows: number;
    buttons: ButtonDef[];
  };

  type DeckConfig = { active: string; profiles: Profile[] };

  let deck = $state<DeckConfig | null>(null);
  let editing = $state<number | null>(null);
  let capturing = $state(false);
  let saveError = $state<string | null>(null);

  const ACTION_LABELS: Record<Action["type"], string> = {
    none: "Kosong",
    launch_app: "Jalankan aplikasi",
    open_url: "Buka tautan",
    hotkey: "Kombinasi tombol",
    text: "Ketik teks",
    media_key: "Tombol media",
    run_script: "Jalankan perintah",
    obs_scene: "Scene OBS",
  };

  const MEDIA_KEYS = [
    "MediaPlayPause",
    "MediaTrackNext",
    "MediaTrackPrevious",
    "MediaStop",
    "AudioVolumeUp",
    "AudioVolumeDown",
    "AudioVolumeMute",
  ];

  const active = $derived(deck?.profiles.find((p) => p.id === deck!.active) ?? null);

  async function load() {
    deck = await invoke<DeckConfig>("deck_config");
  }

  async function save() {
    if (!deck) return;
    try {
      await invoke("set_deck_config", { deck });
      saveError = null;
    } catch (e) {
      saveError = String(e);
    }
  }

  /// Bentuk kosong untuk tiap jenis aksi, supaya ganti jenis tidak
  /// meninggalkan field dari jenis sebelumnya.
  function blankAction(type: Action["type"]): Action {
    switch (type) {
      case "launch_app":
        return { type, path: "", args: [] };
      case "open_url":
        return { type, url: "" };
      case "hotkey":
        return { type, keys: [] };
      case "text":
        return { type, text: "" };
      case "media_key":
        return { type, key: "MediaPlayPause" };
      case "run_script":
        return { type, command: "", args: [] };
      case "obs_scene":
        return { type, scene: "" };
      default:
        return { type: "none" };
    }
  }

  function buttonAt(idx: number): ButtonDef | undefined {
    return active?.buttons.find((b) => b.idx === idx);
  }

  function ensureButton(idx: number): ButtonDef {
    const existing = buttonAt(idx);
    if (existing) return existing;
    const created: ButtonDef = {
      idx,
      label: "Tombol",
      style: "normal",
      action: { type: "none" },
    };
    active!.buttons.push(created);
    return created;
  }

  function removeButton(idx: number) {
    if (!active) return;
    active.buttons = active.buttons.filter((b) => b.idx !== idx);
    editing = null;
    save();
  }

  async function resize(cols: number, rows: number) {
    if (!active) return;
    active.cols = cols;
    active.rows = rows;
    // Tombol di luar grid baru akan jadi tidak terlihat di HP, jadi dibuang
    // sekalian daripada diam-diam menghilang.
    active.buttons = active.buttons.filter((b) => b.idx < cols * rows);
    await save();
  }

  /// Rekam kombinasi tombol berikutnya yang ditekan user.
  function captureHotkey(button: ButtonDef) {
    capturing = true;
    const onKey = (e: KeyboardEvent) => {
      e.preventDefault();
      const keys: string[] = [];
      if (e.ctrlKey) keys.push("ControlLeft");
      if (e.shiftKey) keys.push("ShiftLeft");
      if (e.altKey) keys.push("AltLeft");
      if (e.metaKey) keys.push("MetaLeft");
      // Modifier sendirian bukan kombinasi; tunggu tombol utamanya.
      if (/^(Control|Shift|Alt|Meta)/.test(e.code)) return;
      keys.push(e.code);

      button.action = { type: "hotkey", keys };
      capturing = false;
      window.removeEventListener("keydown", onKey, true);
      save();
    };
    window.addEventListener("keydown", onKey, true);
  }

  const ICON_TYPES = ["image/png", "image/jpeg", "image/webp", "image/svg+xml"];
  const MAX_ICON = 512 * 1024;

  /// Baca berkas yang dipilih lalu kirim sebagai base64.
  ///
  /// `<input type="file">` di webview sudah cukup; tidak perlu plugin dialog
  /// hanya untuk memilih satu ikon.
  async function pickIcon(button: ButtonDef, event: Event) {
    const input = event.currentTarget as HTMLInputElement;
    const file = input.files?.[0];
    input.value = "";
    if (!file || !active) return;

    if (!ICON_TYPES.includes(file.type)) {
      saveError = `Tipe ${file.type || "tidak dikenal"} tidak didukung. Pakai PNG, JPEG, WebP, atau SVG.`;
      return;
    }
    if (file.size > MAX_ICON) {
      saveError = `Ikon ${Math.round(file.size / 1024)} KB, batasnya ${MAX_ICON / 1024} KB.`;
      return;
    }

    const bytes = new Uint8Array(await file.arrayBuffer());
    let binary = "";
    for (const b of bytes) binary += String.fromCharCode(b);

    try {
      button.icon_id = await invoke<string>("set_button_icon", {
        profileId: active.id,
        idx: button.idx,
        mime: file.type,
        dataB64: btoa(binary),
      });
      saveError = null;
    } catch (e) {
      saveError = String(e);
    }
  }

  async function clearIcon(button: ButtonDef) {
    if (!active) return;
    try {
      await invoke("clear_button_icon", { profileId: active.id, idx: button.idx });
      button.icon_id = null;
      saveError = null;
    } catch (e) {
      saveError = String(e);
    }
  }

  onMount(load);
</script>

<section>
  <div class="head">
    <h2>Deck</h2>
    {#if active}
      <div class="size">
        <label>
          Kolom
          <input
            type="number"
            min="1"
            max="12"
            value={active.cols}
            onchange={(e) => resize(+e.currentTarget.value, active.rows)}
          />
        </label>
        <label>
          Baris
          <input
            type="number"
            min="1"
            max="12"
            value={active.rows}
            onchange={(e) => resize(active.cols, +e.currentTarget.value)}
          />
        </label>
      </div>
    {/if}
  </div>

  {#if saveError}
    <p class="error">{saveError}</p>
  {/if}

  {#if active}
    <div class="grid" style="grid-template-columns: repeat({active.cols}, 1fr)">
      {#each Array(active.cols * active.rows) as _, idx (idx)}
        {@const button = buttonAt(idx)}
        <button
          class="cell"
          class:filled={!!button}
          class:selected={editing === idx}
          style={button?.color ? `--tint: ${button.color}` : ""}
          onclick={() => {
            ensureButton(idx);
            editing = idx;
          }}
        >
          {button?.label ?? "+"}
        </button>
      {/each}
    </div>

    {#if editing !== null}
      {@const button = buttonAt(editing)}
      {#if button}
        <div class="editor">
          <div class="row">
            <label class="grow">
              Label
              <input bind:value={button.label} onblur={save} maxlength="32" />
            </label>
            <label>
              Warna
              <input
                type="color"
                value={button.color ?? "#2f6fed"}
                onchange={(e) => {
                  button.color = e.currentTarget.value;
                  save();
                }}
              />
            </label>
          </div>

          <div class="row">
            <label class="grow">
              Ikon
              <div class="row">
                <input
                  type="file"
                  accept="image/png,image/jpeg,image/webp,image/svg+xml"
                  onchange={(e) => pickIcon(button, e)}
                />
                {#if button.icon_id}
                  <button class="ghost" onclick={() => clearIcon(button)}>Hapus</button>
                {/if}
              </div>
            </label>
            <label>
              Gaya
              <select
                value={button.style}
                onchange={(e) => {
                  button.style = e.currentTarget.value as ButtonDef["style"];
                  save();
                }}
              >
                <option value="normal">Biasa</option>
                <option value="toggle">Toggle</option>
              </select>
            </label>
          </div>

          <label>
            Aksi
            <select
              value={button.action.type}
              onchange={(e) => {
                button.action = blankAction(e.currentTarget.value as Action["type"]);
                save();
              }}
            >
              {#each Object.entries(ACTION_LABELS) as [value, label] (value)}
                <option {value}>{label}</option>
              {/each}
            </select>
          </label>

          {#if button.action.type === "launch_app"}
            <label>
              Path aplikasi
              <input
                bind:value={button.action.path}
                onblur={save}
                placeholder="notepad.exe"
              />
            </label>
          {:else if button.action.type === "open_url"}
            <label>
              URL
              <input bind:value={button.action.url} onblur={save} placeholder="https://" />
            </label>
          {:else if button.action.type === "hotkey"}
            <label>
              Kombinasi
              <div class="row">
                <input
                  class="grow"
                  readonly
                  value={button.action.keys.join(" + ") || "belum diset"}
                />
                <button onclick={() => captureHotkey(button)} disabled={capturing}>
                  {capturing ? "Tekan tombolnya…" : "Rekam"}
                </button>
              </div>
            </label>
          {:else if button.action.type === "text"}
            <label>
              Teks
              <textarea bind:value={button.action.text} onblur={save} rows="3"></textarea>
            </label>
          {:else if button.action.type === "media_key"}
            <label>
              Tombol
              <select bind:value={button.action.key} onchange={save}>
                {#each MEDIA_KEYS as key (key)}
                  <option value={key}>{key}</option>
                {/each}
              </select>
            </label>
          {:else if button.action.type === "run_script"}
            <label>
              Perintah
              <input bind:value={button.action.command} onblur={save} />
            </label>
            <p class="warn">
              Perintah dijalankan dengan hak akses akunmu. Isi hanya dengan yang kamu
              tulis sendiri.
            </p>
          {:else if button.action.type === "obs_scene"}
            <label>
              Nama scene
              <input bind:value={button.action.scene} onblur={save} />
            </label>
            {#if button.style !== "toggle"}
              <p class="warn">
                Setel gaya ke Toggle kalau ingin tombol ini menyala saat scene-nya
                sedang aktif.
              </p>
            {/if}
          {/if}

          <div class="row end">
            <button class="ghost" onclick={() => removeButton(button.idx)}>
              Hapus tombol
            </button>
            <button onclick={() => (editing = null)}>Tutup</button>
          </div>
        </div>
      {/if}
    {/if}
  {/if}
</section>

<style>
  .head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
  }

  h2 {
    margin: 0 0 12px;
    font-size: 13px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--muted);
  }

  .size {
    display: flex;
    gap: 12px;
    margin-bottom: 12px;
  }

  .size label {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 12px;
    color: var(--muted);
  }

  .size input {
    width: 52px;
  }

  .grid {
    display: grid;
    gap: 8px;
  }

  .cell {
    aspect-ratio: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 4px;
    font-size: 13px;
    text-align: center;
    overflow: hidden;
    color: var(--muted);
    background: none;
    border: 1px dashed var(--line);
    border-radius: 10px;
    cursor: pointer;
  }

  .cell.filled {
    color: var(--fg);
    background: color-mix(in srgb, var(--tint, var(--line)) 22%, transparent);
    border-style: solid;
    border-color: var(--tint, var(--line));
  }

  .cell.selected {
    outline: 2px solid var(--accent);
    outline-offset: 2px;
  }

  .editor {
    display: flex;
    flex-direction: column;
    gap: 12px;
    margin-top: 16px;
    padding: 16px;
    border: 1px solid var(--line);
    border-radius: 12px;
  }

  .editor label {
    display: flex;
    flex-direction: column;
    gap: 4px;
    font-size: 12px;
    color: var(--muted);
  }

  .row {
    display: flex;
    gap: 12px;
    align-items: flex-end;
  }

  .row.end {
    justify-content: flex-end;
  }

  .grow {
    flex: 1;
  }

  input,
  select,
  textarea {
    padding: 7px 9px;
    font: inherit;
    font-size: 14px;
    color: var(--fg);
    background: var(--bg);
    border: 1px solid var(--line);
    border-radius: 8px;
  }

  input:focus,
  select:focus,
  textarea:focus {
    border-color: var(--accent);
    outline: none;
  }

  input[type="color"] {
    width: 44px;
    height: 34px;
    padding: 2px;
  }

  .warn {
    margin: 0;
    font-size: 12px;
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
