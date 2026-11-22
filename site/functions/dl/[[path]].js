// Downloads from the R2 bucket `pinshot` (bound as BUCKET in site/wrangler.toml): /dl/<key>, e.g.
// /dl/PinShot-Setup.exe (the latest), /dl/v1.0.2/PinShot-Setup-1.0.2.exe, /dl/latest.json. Put there by
// packaging/publish.ps1.
export async function onRequestGet({ params, env }) {
  const key = (params.path || []).join("/");
  if (!key || key.includes("..")) return new Response("Not found", { status: 404 });
  const obj = await env.BUCKET.get(key);
  if (!obj) return new Response("Not found", { status: 404 });
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("etag", obj.httpEtag);
  if (key.endsWith(".json")) {
    headers.set("content-type", "application/json; charset=utf-8");
    headers.set("cache-control", "no-cache");
  } else {
    headers.set("content-type", "application/octet-stream");
    headers.set("content-disposition", `attachment; filename="${key.split("/").pop()}"`);
    headers.set("cache-control", key.includes("/") ? "public, max-age=31536000, immutable" : "public, max-age=300");
  }
  return new Response(obj.body, { headers });
}

export async function onRequestHead({ params, env }) {
  const key = (params.path || []).join("/");
  if (!key || key.includes("..")) return new Response(null, { status: 404 });
  const obj = await env.BUCKET.head(key);
  if (!obj) return new Response(null, { status: 404 });
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("etag", obj.httpEtag);
  if (typeof obj.size === "number") headers.set("content-length", String(obj.size));
  if (key.endsWith(".json")) {
    headers.set("content-type", "application/json; charset=utf-8");
    headers.set("cache-control", "no-cache");
  } else {
    headers.set("content-type", "application/octet-stream");
    headers.set("content-disposition", `attachment; filename="${key.split("/").pop()}"`);
    headers.set("cache-control", key.includes("/") ? "public, max-age=31536000, immutable" : "public, max-age=300");
  }
  return new Response(null, { status: 200, headers });
}
