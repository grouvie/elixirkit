# Building Desktop Apps with Tauri

Elixir and Phoenix are great for building web applications with rich, server-driven UIs. With ElixirKit, we can bring that tech stack to the desktop, starting an Elixir app and communicating with it from Rust.

In this guide we will learn how to take a Phoenix LiveView app and distribute it as a desktop app using [Tauri](https://tauri.app). Tauri is a Rust framework for building cross-platform apps for all major desktop and mobile platforms. Tauri is an ideal companion to ElixirKit -- it handles cross-platform windowing, native OS integration, and bundling this all together into installers for each platform.

You can see the final app source code at [`examples/tauri_project`](https://github.com/livebook-dev/elixirkit/tree/main/examples/tauri_project).

Here, we will re-create it from scratch. Let's get started!

## Phoenix

First, let's create a Phoenix app. In this guide we will skip Ecto and Gettext integration. Run:

```sh
$ mix archive.install hex phx_new
$ mix phx.new example --no-ecto --no-gettext
$ cd example
```

Let's add our first LiveView, a simple counter at `lib/example_web/live/home_live.ex`:

```elixir
defmodule ExampleWeb.HomeLive do
  use ExampleWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, count: 0)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex items-center justify-between m-4">
      <div class="flex items-center gap-2">
        <span>Count: <span class="font-mono">{@count}</span></span>
        <button phx-click="inc" class="btn btn-sm btn-outline">+</button>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("inc", _params, socket) do
    count = socket.assigns.count + 1
    {:noreply, assign(socket, count: count)}
  end
end
```

And change the router accordingly:

```diff
  scope "/", ExampleWeb do
    pipe_through :browser

-   get "/", PageController, :home
+   live "/", HomeLive
  end
```

Run `mix phx.server` to ensure everything works well.

## Tauri

Now, let's create a Tauri app:

```sh
$ sh <(curl https://create.tauri.app/sh)
Project name› example
Identifier› com.example.Example
Choose which language to use for your frontend› Rust - (cargo)
Choose your UI template› Vanilla
```

In this guide we are not going to use Tauri frontend integration (because we have LiveView for that!) so we can keep just the `src-tauri` directory. I like to put my Tauri apps inside Phoenix projects into `tauri`, `rel/app`, etc or keep `src-tauri` at the Phoenix project root. In this guide, we're gonna do the latter. In Phoenix project root, run:

```sh
$ mv example/src-tauri .
$ rm -rf example
```

Finally, let's remove frontend configuration from `src-tauri/tauri.conf.json`:

```diff
  "build": {
-   "frontendDist": "../src"
  },
```

Now, let's start the Tauri app from Phoenix project root:

```sh
$ cargo tauri dev
```

We should see a WebView window with text:

```text
asset not found: index.html
```

That's OK, we're gonna point the app to our LiveView next!

## Phoenix + Tauri

First, let's add ElixirKit to mix.exs dependencies:

```diff
+ {:elixirkit, github: "livebook-dev/elixirkit"}
```

and run `mix deps.get`.

Next, add `ElixirKit.Bridge` to supervision tree:

```diff
+ pubsub = System.get_env("ELIXIRKIT_PUBSUB")

  children = [
    ...
    {Phoenix.PubSub, name: Example.PubSub},
+   {ElixirKit.Bridge,
+    connect: pubsub || :ignore,
+    on_exit: fn -> System.stop() end},
    ExampleWeb.Endpoint,
+   {Task,
+    fn ->
+      if pubsub do
+        ElixirKit.Bridge.broadcast("messages", "ready")
+      end
+    end}
  ]
```

If `ELIXIRKIT_PUBSUB` env var is set, which we will from our Tauri app, we connect to the bridge and send a ready message. Otherwise, we start `ElixirKit.Bridge` with `connect: :ignore` which does nothing, so we can develop and test the Phoenix side in isolation.

This is an incremental seam on the Elixir side only. Today `ElixirKit.Bridge`
still uses the same TCP `ElixirKit.PubSub` transport underneath, so the
environment variable and transport behavior do not change. No NIF-backed
bridge, mobile runtime, or wrapper CLI is being introduced underneath.
Structured bridge envelopes now layer over one reserved internal topic on top
of that same transport, while raw topic/message PubSub usage remains
unchanged.

Brokered request/response also uses that same connection via
`ElixirKit.Bridge.call/2`. Internally Elixir keeps one shared router per
bridge connection, implemented internally as `ElixirKit.Bridge.Router`, and
matches responses by request id on the reserved bridge topic. Today that path
is intentionally narrow: the built-in core-owned operations are still just
`bridge.echo` and `bridge.capabilities`, while explicitly registered host
operations can now extend that path one namespace at a time. The example app
below still uses the raw `"ready"` topic flow unchanged.

Capability lookup now rides over that same broker path with
`ElixirKit.Bridge.capabilities/0`. The returned data is capability truth, not
authorization: action-level availability is reported separately from permission
state. The registry aggregates the built-in bridge namespace with explicitly
registered host namespaces. Registration is still explicit in
`src-tauri/src/lib.rs`; the root `elixirkit` crate is still the bridge/core,
and the first extraction pass keeps capability-specific host code in separate
local crates and Elixir packages rather than an omnibus plugin rollout.

For plugin-style capability operations we now use JSON only for the inner
request and success-response bodies. The outer bridge envelope, the reserved
bridge topic, and the binary request/response framing all stay exactly the
same.

Next, let's add `elixirkit` to `Cargo.toml` dependencies. ElixirKit Hex package ships with the `elixirkit` crate inside so we can use a path dependency like this:

```diff
  [dependencies]
  tauri = { version = "2", features = [] }
  tauri-plugin-clipboard-manager = "2"
  tauri-plugin-opener = "2"
+ elixirkit = { path = "../deps/elixirkit/elixirkit_rs" }
```

Let's change `tauri.conf.json` to not create any windows initially. We'll create them programmatically once LiveView is ready:

```diff
- "windows": [
-   {
-     "title": "example",
-     "width": 800,
-     "height": 600
-   }
- ],
```

Finally, let's start Elixir from the Tauri app and register a few real host
capability slices explicitly in `src-tauri/src/lib.rs`. The stable seam is
`register_capability_handlers`: it keeps the declared actions and their
handlers together while still leaving registration fully app-owned. Here's the
relevant code:

```rust
use tauri::Manager;

fn register_host_capabilities(pubsub: &elixirkit::PubSub, app_handle: &tauri::AppHandle) {
    tauri_plugin_elixir_opener::register(pubsub, app_handle)
        .expect("failed to register opener capability");
    tauri_plugin_elixir_clipboard::register(pubsub, app_handle)
        .expect("failed to register clipboard capability");
    tauri_plugin_elixir_window::register(pubsub, app_handle)
        .expect("failed to register window capability");
}
```

We still subscribe to the `messages` PubSub topic exactly as before. Once
Elixir sends the `ready` message, we create a window pointing to our LiveView.
The new part is the explicit registration contract: the example app now
registers `opener`, `clipboard`, and `window` without hardcoding any of them
into the bridge core. `opener` uses Tauri's official opener plugin,
`clipboard` uses Tauri's official clipboard plugin, and `window` uses direct
Tauri core APIs. The capability-specific host code now lives in separate local
crates under `crates/`, while the Elixir wrappers (`ElixirKit.Opener`,
`ElixirKit.Clipboard`, and `ElixirKit.Window`) live in separate local packages
under `packages/`. The raw `"ready"` / `"count"` PubSub flow stays unchanged.
The example app's Mix project depends on those wrapper packages explicitly:

```elixir
{:elixirkit, path: "../.."},
{:elixirkit_opener, path: "../../packages/elixirkit_opener"},
{:elixirkit_clipboard, path: "../../packages/elixirkit_clipboard"},
{:elixirkit_window, path: "../../packages/elixirkit_window"}
```

This is the first extraction pass only. The transport, outer binary bridge
envelope, broker path, and JSON-inside-binary capability payload convention
all stay the same. Run the following to verify:

```sh
$ cargo tauri dev
```

When the example boots under Tauri now, the home screen is no longer just the
old counter. It still keeps the original `"ready"` and `"count"` topic flow,
and it also exposes a small bridge dashboard that can:

- refresh `ElixirKit.Bridge.capabilities/0`
- round-trip `bridge.echo`
- read and write the clipboard
- list and rename host windows
- dispatch opener calls

Those UI actions exercise the extracted Elixir capability packages while the
host-side registration still stays explicit in `src-tauri/src/lib.rs`.

We can add more broadcasts from either side. For example, let's broadcast a message whenever counter is increased. Change `lib/example_web/live/home_live.ex`:

```diff
  @impl true
  def handle_event("inc", _params, socket) do
    count = socket.assigns.count + 1
+   ElixirKit.Bridge.broadcast("messages", "count:#{count}")
    {:noreply, assign(socket, count: count)}
  end
```

We should now see in terminal output:

```txt
[rust] count:1
...
[rust] count:2
...
```

For local docs generation, each extracted Elixir capability package now also
has its own `mix docs` flow, and running `mix docs` from the repo root
generates the root docs, Rust docs, and copies the package docs into
`doc/packages/...`.

## Release

Time to release our app into the wild!

Currently we run our Elixir part by executing `mix phx.server` which requires Elixir to be installed. Let's create an Elixir _release_ which will contain our app and all of its dependencies including Elixir and OTP itself. Releases include the Erlang VM by default so they are self-contained, but you need to make sure that the Erlang VM you're using to build the release is self-contained too and cannot have external dependencies because they may be missing on your end-user systems. We'll address this in the "Distribute" section and in the meantime let's finish up creating the release.

First, let's change `tauri.conf.json`:

```diff
  "productName": "example",
  "version": "0.1.0",
  "identifier": "com.example.Example",
  "build": {
+   "beforeBuildCommand": "MIX_ENV=prod mix do compile + assets.deploy + release --overwrite --path src-tauri/target/rel"
  },
  ...
  "bundle": {
    "active": true,
+   "resources": {
+     "target/rel": "rel"
+   },
    "targets": "all",
```

Tauri runs `beforeBuildCommand` before compiling Rust code. The `resources` config tells the bundler to include that directory in the app bundle.

Next, let's change `src-tauri/src/lib.rs` to use `mix phx.server` in debug builds and the release in, well, release builds!

```diff
              tauri::async_runtime::spawn_blocking(move || {
-                 let mut command = elixir_command();
+                 let rel_dir = app_handle.path().resource_dir().unwrap().join("rel");
+                 let mut command = elixir_command(&rel_dir);

  ...

- fn elixir_command() -> std::process::Command {
-     let mut command = elixirkit::mix("phx.server", &[]);
-     command.current_dir("..");
-     command
- }
+ fn elixir_command(rel_dir: &std::path::Path) -> std::process::Command {
+     if cfg!(debug_assertions) {
+         let mut command = elixirkit::mix("phx.server", &[]);
+         command.current_dir("..");
+         command
+     } else {
+         let mut command = elixirkit::release(rel_dir, "example");
+         command.env("PHX_SERVER", "true");
+         command.env("PHX_HOST", "127.0.0.1");
+         command.env("PORT", "4000");
+         command.env("SECRET_KEY_BASE", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
+         command
+     }
  }
```

Note, we hardcode `SECRET_KEY_BASE` value for brevity. Depending on your security requirements, you may want to generate a random key instead. Similarly, we hardcode `PORT` to `4000`. You may want to choose reasonably random port for your app that's unlikely to be taken instead.

Finally, let's build it!

```sh
$ cargo tauri build
```

On macOS, I like to use the following command to try out the app as it will print standard output and error to the console:

```sh
$ open -W --stderr `tty` --stdout `tty` src-tauri/target/release/bundle/macos/example.app
```

## Distribute

Now that we have our release, there's a few things left to do to distribute our app to end-users.

On macOS we need to code sign (and notarize, but more on that later) our app. Tauri handles it automatically for Rust code, but since we're embedding an Elixir release, we need to sign it ourselves. Code signing is a wide topic, outside of the scope of this guide, but long story short we need to sign any native code in our app or else end-users will get security warnings and will need to perform manual steps to allow it.

See [Tauri "macOS Code Signing" guide](https://v2.tauri.app/distribute/sign/macos/) to get started. Once you have signing identity, which we will keep in an `APPLE_SIGNING_IDENTITY` environment variable, proceed with the following code changes. Note: signing macOS apps with a developer certificate requires a paid Apple Developer Program subscription.

ElixirKit ships with `ElixirKit.Release.codesign/1` for code signing releases on macOS. First, add release configuration to `mix.exs`:

```diff
  def project do
    [
      app: :example,
      version: "0.1.0",
      ...
      aliases: aliases(),
+     releases: releases()
    ]
  end

  ...

+ defp releases do
+   [
+     example: [
+       steps: [:assemble, &ElixirKit.Release.codesign/1],
+       entitlements: "#{__DIR__}/src-tauri/App.entitlements"
+     ]
+   ]
+ end
```

and add a `src-tauri/App.entitlements` file:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key>
  <true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
  <true/>
  <key>com.apple.security.cs.allow-dyld-environment-variables</key>
  <true/>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
```

Finally, we need to notarize our application. There's a ["Notarization"](https://v2.tauri.app/distribute/sign/macos/#notarization) section in the Tauri macOS Code Signing guide we have seen previously. Tauri tooling automatically picks up `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_PASSWORD`, `APPLE_TEAM_ID`, so when we provide these to `cargo tauri build`, our app will be signed and notarized:

```sh
$ APPLE_SIGNING_IDENTITY="***" \
  APPLE_ID="***" \
  APPLE_PASSWORD="***" \
  APPLE_TEAM_ID="***" \
  cargo tauri build
```

We can check if everything went well using `spctl`:

```sh
$ spctl -a -t exec -vvv src-tauri/target/release/bundle/macos/example.app
src-tauri/target/release/bundle/macos/example.app: accepted
source=Notarized Developer ID
origin=Developer ID Application: ***
```

Tauri has a similar [code-signing guide for Windows](https://v2.tauri.app/distribute/sign/windows/#azure-code-signing) and for other platforms too.

Finally, Tauri project maintains [`tauri-apps/tauri-action`](https://github.com/tauri-apps/tauri-action) that can automate building and even uploading release artifacts on GitHub Actions. If you're using GitHub Actions and targetting multiple platforms, you probably want something like the following.

```yaml
strategy:
  fail-fast: false
  matrix:
    include:
      - platform: macos-15
        target: "aarch64-apple-darwin"
      - platform: macos-15-intel
        target: "x86_64-apple-darwin"

      - platform: ubuntu-22.04-arm
        target: "aarch64-unknown-linux-gnu"
      - platform: ubuntu-22.04
        target: "x86_64-unknown-linux-gnu"

      - platform: windows-2022
        target: "x86_64-pc-windows-msvc"
runs-on: ${{ matrix.platform }}
steps:
  - uses: erlef/setup-beam@v1
    with:
      otp-version: ${{ env.otp-version }}
      elixir-version: ${{ env.elixir-version }}
  - name: Setup Rust
    uses: dtolnay/rust-toolchain@stable
    with:
      targets: ${{ matrix.target }}

  - name: Build Tauri app
    uses: tauri-apps/tauri-action@v0.6
    env:
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      MIX_ENV: prod

      # macOS codesigning/notarization
      APPLE_CERTIFICATE: ${{ secrets.APPLE_CERTIFICATE_P12_BASE64 }}
      APPLE_CERTIFICATE_PASSWORD: ${{ secrets.APPLE_CERTIFICATE_P12_PASSWORD }}
      APPLE_SIGNING_IDENTITY: ${{ secrets.APPLE_SIGNING_IDENTITY }}
      APPLE_ID: ${{ secrets.APPLE_ID }}
      APPLE_PASSWORD: ${{ secrets.APPLE_PASSWORD }}
      APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}

      # Windows codesigning
      AZURE_CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
      AZURE_CLIENT_SECRET: ${{ secrets.AZURE_CLIENT_SECRET }}
      AZURE_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}
      AZURE_TRUSTED_SIGNING_ACCOUNT_NAME: ${{ secrets.AZURE_TRUSTED_SIGNING_ACCOUNT_NAME }}
      AZURE_CERTIFICATE_PROFILE_NAME: ${{ secrets.AZURE_CERTIFICATE_PROFILE_NAME }}
```

At the moment of this writing, `erlef/setup-beam` downloads Erlang/OTP from <https://github.com/erlang/otp/releases> for Windows and <https://github.com/erlef/otp_builds> for macOS. Windows and macOS builds are statically linking OpenSSL so they are self-contained, but Linux (Ubuntu) builds aren't. When targetting multiple Linux distributions, you need either per-distribution builds or use solutions like AppImage.

## Conclusion

In this guide, we took a Phoenix LiveView app and turned it into a desktop application using Tauri and ElixirKit. We connected Elixir and Rust via PubSub, built a self-contained release that bundles the BEAM runtime, and signed it for distribution.

In this guide we focused on distributing for macOS and only briefly mentioned Windows and Linux. See Tauri [Windows](https://v2.tauri.app/distribute/#windows) and [Linux](https://v2.tauri.app/distribute/#linux) distribution guides for more information.

Tauri project maintains a number of high quality plugins worth exploring at <https://v2.tauri.app/plugin>. In [Livebook Desktop](https://livebook.dev/#install), which ElixirKit was extracted out of, at the moment of this writing we use:

- [Single Instance](https://v2.tauri.app/plugin/single-instance/) - ensure only one copy of the app is running (crucial on Windows!)
- [Updater](https://v2.tauri.app/plugin/updater/) - automatic updates
- [Deep Link](https://v2.tauri.app/plugin/deep-linking/) - register custom URL schemes (e.g. `example://`)
- [Tray Icon](https://v2.tauri.app/plugin/tray-icon/) - add a system tray icon

Happy hacking!
