// Vector annotation path generation, mosaic pixelation, and PNG export (100% pure MoonBit + @pixels).

///|
fn vec_layer(d : String, fill : Int64, stroke? : Int64 = 0L, width? : Double = 0.0) -> @pixels.VectorPath {
  { d, fill, stroke, width, even_odd: false, sx: 1.0, sy: 1.0, tx: 0.0, ty: 0.0 }
}

///|
fn rect_svg(x : Double, y : Double, w : Double, h : Double) -> String {
  "M\{x} \{y}H\{x + w}V\{y + h}H\{x}Z"
}

///|
fn ellipse_svg(cx : Double, cy : Double, rx : Double, ry : Double) -> String {
  if rx <= 0.5 || ry <= 0.5 {
    return ""
  }
  let k = 0.5522847498
  let ox = rx * k
  let oy = ry * k
  "M\{cx - rx} \{cy}" +
  "C\{cx - rx} \{cy - oy} \{cx - ox} \{cy - ry} \{cx} \{cy - ry}" +
  "C\{cx + ox} \{cy - ry} \{cx + rx} \{cy - oy} \{cx + rx} \{cy}" +
  "C\{cx + rx} \{cy + oy} \{cx + ox} \{cy + ry} \{cx} \{cy + ry}" +
  "C\{cx - ox} \{cy + ry} \{cx - rx} \{cy + oy} \{cx - rx} \{cy}Z"
}

///|
fn arrow_svg(x0 : Double, y0 : Double, x1 : Double, y1 : Double, sw : Double) -> String {
  let dx = x1 - x0
  let dy = y1 - y0
  let len = (dx * dx + dy * dy).sqrt()
  if len < 4.0 {
    return ""
  }
  let ux = dx / len
  let uy = dy / len
  let px = -uy
  let py = ux
  let head_len = @cmp.minimum(len * 0.45, @cmp.maximum(12.0, sw * 4.2))
  let head_w = head_len * 0.58
  let shaft_w = @cmp.maximum(1.2, sw * 0.48)
  let bx = x1 - ux * head_len
  let by = y1 - uy * head_len
  "M\{x0 + px * shaft_w * 0.5} \{y0 + py * shaft_w * 0.5}" +
  "L\{bx + px * shaft_w * 0.7} \{by + py * shaft_w * 0.7}" +
  "L\{bx + px * head_w} \{by + py * head_w}" +
  "L\{x1} \{y1}" +
  "L\{bx - px * head_w} \{by - py * head_w}" +
  "L\{bx - px * shaft_w * 0.7} \{by - py * shaft_w * 0.7}" +
  "L\{x0 - px * shaft_w * 0.5} \{y0 - py * shaft_w * 0.5}Z"
}

///|
/// Crisp vector stroke path for digits 0..9 centered at (cx, cy) with height `h`.
fn digit_svg(d : Int, cx : Double, cy : Double, h : Double) -> String {
  let w = h * 0.56
  let x0 = cx - w / 2.0
  let x1 = cx + w / 2.0
  let y0 = cy - h / 2.0
  let ym = cy
  let y1 = cy + h / 2.0
  match d {
    0 => "M\{x0} \{y0}H\{x1}V\{y1}H\{x0}Z"
    1 => "M\{cx - w * 0.25} \{y0 + h * 0.2}L\{cx} \{y0}V\{y1}"
    2 => "M\{x0} \{y0 + h * 0.2}V\{y0}H\{x1}V\{ym}H\{x0}V\{y1}H\{x1}"
    3 => "M\{x0} \{y0}H\{x1}V\{y1}H\{x0}M\{x0} \{ym}H\{x1}"
    4 => "M\{x0} \{y0}V\{ym}H\{x1}M\{x1} \{y0}V\{y1}"
    5 => "M\{x1} \{y0}H\{x0}V\{ym}H\{x1}V\{y1}H\{x0}"
    6 => "M\{x1} \{y0}H\{x0}V\{y1}H\{x1}V\{ym}H\{x0}"
    7 => "M\{x0} \{y0}H\{x1}L\{cx} \{y1}"
    8 => "M\{x0} \{y0}H\{x1}V\{y1}H\{x0}ZM\{x0} \{ym}H\{x1}"
    9 => "M\{x1} \{ym}H\{x0}V\{y0}H\{x1}V\{y1}H\{x0}"
    _ => ""
  }
}

///|
fn number_svg(n : Int, cx : Double, cy : Double, h : Double) -> String {
  if n < 10 {
    return digit_svg(n, cx, cy, h)
  }
  let tens = (n / 10) % 10
  let ones = n % 10
  let gap = h * 0.42
  digit_svg(tens, cx - gap, cy, h * 0.86) + digit_svg(ones, cx + gap, cy, h * 0.86)
}

///|
/// Sample average color from `frozen_bmp` (32-bit top-down BGRA at offset 54) at physical rect `(px, py, pw, ph)`.
fn sample_bmp_block_color(bmp : Bytes, mw : Int, mh : Int, px : Int, py : Int, pw : Int, ph : Int) -> Int64 {
  if bmp.length() < 54 + mw * mh * 4 {
    return 0x808080FFL
  }
  let x0 = @cmp.maximum(0, px)
  let y0 = @cmp.maximum(0, py)
  let x1 = @cmp.minimum(mw, px + pw)
  let y1 = @cmp.minimum(mh, py + ph)
  if x1 <= x0 || y1 <= y0 {
    return 0x808080FFL
  }
  let mut sr = 0
  let mut sg = 0
  let mut sb = 0
  let mut cnt = 0
  let step_y = @cmp.maximum(1, (y1 - y0) / 3)
  let step_x = @cmp.maximum(1, (x1 - x0) / 3)
  let mut y = y0
  while y < y1 {
    let mut x = x0
    while x < x1 {
      let off = 54 + (y * mw + x) * 4
      sb += bmp[off].to_int()
      sg += bmp[off + 1].to_int()
      sr += bmp[off + 2].to_int()
      cnt += 1
      x += step_x
    }
    y += step_y
  }
  if cnt == 0 {
    return 0x808080FFL
  }
  let r = (sr / cnt).to_int64()
  let g = (sg / cnt).to_int64()
  let b = (sb / cnt).to_int64()
  (r << 24) | (g << 16) | (b << 8) | 0xFFL
}

///|
/// Build vector layers for annotations, shifted by `(-ox, -oy)` and scaled by `scale`.
fn annotations_vector(
  anns : Array[Annotation],
  active : Annotation?,
  ox : Double,
  oy : Double,
  w : Double,
  h : Double,
  scale : Double,
  bmp : Bytes,
  mw : Int,
  mh : Int,
  pt_scale : Double,
) -> @pixels.Vector? {
  let all = anns.copy()
  match active {
    Some(a) => all.push(a)
    None => ()
  }
  if all.is_empty() || w <= 0.0 || h <= 0.0 {
    return None
  }
  let layers : Array[@pixels.VectorPath] = []
  let tx = fn(x : Double) { (x - ox) * scale }
  let ty = fn(y : Double) { (y - oy) * scale }

  // Mosaic blocks first (underneath strokes)
  for a in all {
    if a.kind == Mosaic {
      let x0 = @cmp.minimum(a.x0, a.x1)
      let y0 = @cmp.minimum(a.y0, a.y1)
      let x1 = @cmp.maximum(a.x0, a.x1)
      let y1 = @cmp.maximum(a.y0, a.y1)
      let blk = @cmp.maximum(8.0, a.stroke * 3.2)
      let mut y = y0
      while y < y1 {
        let bh = @cmp.minimum(blk, y1 - y)
        let mut x = x0
        while x < x1 {
          let bw = @cmp.minimum(blk, x1 - x)
          let px = (x * pt_scale).round().to_int()
          let py = (y * pt_scale).round().to_int()
          let pw = @cmp.maximum(1, (bw * pt_scale).round().to_int())
          let ph = @cmp.maximum(1, (bh * pt_scale).round().to_int())
          let col = sample_bmp_block_color(bmp, mw, mh, px, py, pw, ph)
          layers.push(vec_layer(rect_svg(tx(x), ty(y), bw * scale, bh * scale), col))
          x += blk
        }
        y += blk
      }
    }
  }

  for a in all {
    let sw = a.stroke * scale
    match a.kind {
      Rect => {
        let x = tx(@cmp.minimum(a.x0, a.x1))
        let y = ty(@cmp.minimum(a.y0, a.y1))
        let rw = (a.x1 - a.x0).abs() * scale
        let rh = (a.y1 - a.y0).abs() * scale
        if rw >= 2.0 && rh >= 2.0 {
          layers.push(vec_layer(rect_svg(x, y, rw, rh), 0L, stroke=a.color, width=sw))
        }
      }
      Ellipse => {
        let cx = tx((a.x0 + a.x1) / 2.0)
        let cy = ty((a.y0 + a.y1) / 2.0)
        let rx = (a.x1 - a.x0).abs() * 0.5 * scale
        let ry = (a.y1 - a.y0).abs() * 0.5 * scale
        let d = ellipse_svg(cx, cy, rx, ry)
        if d != "" {
          layers.push(vec_layer(d, 0L, stroke=a.color, width=sw))
        }
      }
      Arrow => {
        let d = arrow_svg(tx(a.x0), ty(a.y0), tx(a.x1), ty(a.y1), sw)
        if d != "" {
          layers.push(vec_layer(d, a.color))
        }
      }
      Pen => {
        if a.pts.length() >= 2 {
          let sb = StringBuilder()
          sb.write_string("M\{tx(a.pts[0].0)} \{ty(a.pts[0].1)}")
          for i in 1..<a.pts.length() {
            sb.write_string("L\{tx(a.pts[i].0)} \{ty(a.pts[i].1)}")
          }
          layers.push(vec_layer(sb.to_string(), 0L, stroke=a.color, width=sw))
        }
      }
      Step => {
        let cx = tx(a.x0)
        let cy = ty(a.y0)
        let r = @cmp.maximum(11.0, sw * 3.5) * scale / @cmp.maximum(1.0, scale) * scale
        layers.push(vec_layer(ellipse_svg(cx, cy, r, r), a.color, stroke=0xFFFFFFFFL, width=1.5 * scale))
        let nd = number_svg(a.step_num, cx, cy, r * 0.95)
        if nd != "" {
          layers.push(vec_layer(nd, 0L, stroke=0xFFFFFFFFL, width=1.8 * scale))
        }
      }
      Mosaic | Select => ()
    }
  }
  Some({ w: w * scale, h: h * scale, layers })
}

///|
/// Render the selected region + annotations to PNG bytes at physical pixel resolution.
fn export_selection_png() -> Bytes? {
  guard sel.untracked() is Some(r) else { return None }
  let bmp = frozen_bmp.val
  let mw = mon_w.val
  let mh = mon_h.val
  let sc = mon_scale.val
  if bmp.length() < 54 + mw * mh * 4 {
    return None
  }
  let px0 = @cmp.maximum(0, (r.x * sc).round().to_int())
  let py0 = @cmp.maximum(0, (r.y * sc).round().to_int())
  let px1 = @cmp.minimum(mw, ((r.x + r.w) * sc).round().to_int())
  let py1 = @cmp.minimum(mh, ((r.y + r.h) * sc).round().to_int())
  let cw = px1 - px0
  let ch = py1 - py0
  if cw <= 0 || ch <= 0 {
    return None
  }
  let anns = annotations.untracked()
  let compress = cfg_png_compress.untracked()
  if anns.is_empty() && compress {
    let fast = ps_encode_crop_png(px0, py0, cw, ch)
    if fast.length() > 8 {
      return Some(fast)
    }
  }
  let canvas = @pixels.Canvas::new(cw, ch)
  let dst = canvas.pixels()
  for y in 0..<ch {
    let sy = py0 + y
    let src_row = 54 + (sy * mw + px0) * 4
    let dst_row = y * cw * 4
    for x in 0..<cw {
      let s = src_row + x * 4
      let d = dst_row + x * 4
      // BMP BGRA -> straight RGBA
      dst[d] = bmp[s + 2]
      dst[d + 1] = bmp[s + 1]
      dst[d + 2] = bmp[s]
      dst[d + 3] = b'\xFF'
    }
  }
  match annotations_vector(
    anns,
    None,
    r.x,
    r.y,
    r.w,
    r.h,
    sc,
    bmp,
    mw,
    mh,
    sc,
  ) {
    Some(vec) => {
      let overlay = vec.rgba(cw, ch)
      canvas.draw(cw, ch, overlay, (0, 0, cw, ch), (0.0, 0.0, cw.to_double(), ch.to_double()), premultiplied=true)
    }
    None => ()
  }
  if compress {
    let compressed = ps_encode_rgba_png(cw, ch, canvas.pixels())
    if compressed.length() > 8 {
      return Some(compressed)
    }
  }
  Some(@pixels.png(cw, ch, canvas.pixels()))
}
