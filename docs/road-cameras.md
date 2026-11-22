# Road cameras as live sources

The Live screens and several demos (Traffic count, Privacy camera, detection and tracking) can take a public
traffic camera as their source:
- a live **HLS stream** (`.m3u8`);
- a **still picture** that the camera replaces every minute or so (the apps reload it).

This repository ships **no camera addresses**: the built-in list (`streams.json` in `Artelico/App` and
`UGenProbe/App`) is empty. You can still:
- **paste one address:** Live > "Stream address" takes any `http(s)://` video, `.m3u8` playlist or `rtsp://` address;
- **load a list:** put a `cameras.json` in the app's Documents folder (see below);
- **build your own list:** with a catalogue (see below).

## Where to find public cameras for testing

Many road authorities publish their cameras openly, usually in a traveller-information site or an open-data
portal:
- **United States:** state departments of transportation run **"511" traveller-information sites**. Many list every
  camera on a map, and several offer live HLS video, not just stills. Search for "<state> 511 traffic cameras".
- **Canada:** most provinces have a 511 site too (mostly still pictures). British Columbia's road information site
  publishes its webcams as a JSON list.
- **Europe and elsewhere:** national and city road authorities often publish camera stills in their open-data
  portals. Search for "<country or city> open data traffic cameras".
- **Your own camera:** an IP camera or a phone running an IP-camera app gives an `rtsp://` or `http://` address on
  your network. The apps' RTSP client (StudioCore) supports Basic and Digest login (`rtsp://user:password@host:554/path`).

Before using a feed:
- **Check its terms of use:** some sites allow personal use only, or ask you not to embed or redistribute.
- **Mind the browser's limits:** browsers can only analyse a feed whose server sends CORS headers, which is why the
  web edition has no camera list. The native apps don't have that limit, and allow plain `http` because many cameras
  use it.
- **Privacy:** cameras show real people and number plates. The Privacy camera demo hides them before anything is
  shown or recorded.

## `cameras.json`: your own list

An array of cameras. Put it in the app's Documents folder:
- **iPad and iPhone:** the Files app, under the app's name;
- **Mac:** `~/Library/Containers/<bundle id>/Data/Documents/`.

The camera list then shows it instead of the built-in one. "Back to the built-in list" removes it again.

```json
[
  {"name": "Main St · 5th Ave", "region": "Somewhere", "country": "USA", "kind": "video",
   "url": "https://example.org/cameras/main-5th/playlist.m3u8"},
  {"name": "Bridge north end", "region": "Somewhere", "country": "Canada", "kind": "image",
   "url": "https://example.org/cameras/1234.jpg"}
]
```

- **`kind`:** `"video"` for an HLS stream, `"image"` for a still picture.
- **Grouping:** cameras are grouped by region and country, and the list can be searched by name or region.

## `streams.json`: a built-in list and catalogues (when you build the apps)

`streams.json` can also be an object with the cameras built into the app and **catalogues**: sites that "Fetch the
full lists from the web" reads (thousands of cameras, not checked one by one).

```json
{
  "cameras": [ … same format as cameras.json … ],
  "catalogues": [
    {"format": "511",  "host": "<a 511 site's host name>", "region": "…", "country": "…"},
    {"format": "list", "list": "https://…/webcams/", "image": "https://…/images/{id}.jpg", "region": "…", "country": "…"}
  ]
}
```

- **`"511"`:** a site on the common 511 platform. The app pages through `https://<host>/List/GetData/Cameras` and
  keeps each camera's open video or still picture.
- **`"list"`:** `list` returns a JSON array of `{id, name, highway_display?, marked_stale?}`, and each camera's
  picture is `image` with `{id}` replaced.
- **The button:** it only appears when there's at least one catalogue.
- **The code:** `StreamCatalog.swift`, in both apps (keep the two copies the same).
