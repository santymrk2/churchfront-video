
const W = 480, H = 270;
// The stage, in degrees from the camera (pan right +, tilt up +).
const people = [
  {name:"Pastor", az:0, el:-4, h:9, color:"#4a7bd0", walk:18},
  {name:"Worship lead", az:-22, el:-6, h:8, color:"#c0563f"},
  {name:"Guitar", az:-34, el:-6, h:8, color:"#5a9b5a"},
  {name:"Keys", az:28, el:-6, h:8, color:"#9b6bc0"},
  {name:"Drums", az:40, el:-4, h:7, color:"#c09b3f"},
];
function stage(ctx, proj, t) {
  const r = (a0, e0, a1, e1, fill) => { const p = proj(a0, e1), q = proj(a1, e0); ctx.fillStyle = fill; ctx.fillRect(p.x, p.y, q.x - p.x, q.y - p.y); };
  r(-90, -40, 90, 60, "#2a2320");            // back wall
  r(-90, -40, 90, -14, "#3b2e25");           // stage floor
  r(-14, 6, 14, 24, "#20344d");              // big screen
  r(-12, 8, 12, 22, "#2f5f8f");
  ctx.fillStyle = "#e8ecf1"; const c = proj(0, 15); ctx.font = `${Math.max(8, proj(4,0).x - proj(0,0).x)}px system-ui`; ctx.textAlign = "center"; ctx.fillText("Welcome", c.x, c.y);
  r(-2.5, -14, 2.5, -6, "#6b4a32");          // pulpit
  r(38, -12, 46, -6, "#555");                // drum riser
  r(24, -9, 32, -7, "#222");                 // keyboard
  for (const p of people) {
    const az = p.walk ? p.az + p.walk * Math.sin(t / 6000) : p.az;
    const top = proj(az, p.el + p.h), feet = proj(az, p.el - 6), head = (feet.y - top.y) / 7;
    ctx.fillStyle = p.color;
    ctx.beginPath(); ctx.roundRect(top.x - head * 1.1, top.y + head * 2, head * 2.2, feet.y - top.y - head * 2, head * 0.6); ctx.fill();
    ctx.fillStyle = "#e0b48f"; ctx.beginPath(); ctx.arc(top.x, top.y + head, head, 0, 7); ctx.fill();
    ctx.fillStyle = "rgba(255,255,255,.75)"; ctx.font = `${Math.max(8, head)}px system-ui`; ctx.fillText(p.name, top.x, feet.y + head * 1.4);
  }
}
function draw(cam, el, t) {
  const v = el.querySelector(".view").getContext("2d"), s = el.querySelector(".strip").getContext("2d");
  const fx = cam.fov, fy = cam.fov * 9 / 16;
  stage(v, (a, e) => ({x: (a - cam.pan) / fx * W + W / 2, y: H / 2 - (e - cam.tilt) / fy * H}), t);
  v.strokeStyle = "rgba(255,255,255,.35)"; v.lineWidth = 1; v.beginPath();
  v.moveTo(W/2 - 10, H/2); v.lineTo(W/2 + 10, H/2); v.moveTo(W/2, H/2 - 10); v.lineTo(W/2, H/2 + 10); v.stroke();
  const SW = 480, SH = 90, sx = a => (a + 90) / 180 * SW, sy = e => SH / 2 - (e - 10) / 50 * SH;
  stage(s, (a, e) => ({x: sx(a), y: sy(e)}), t);
  s.strokeStyle = cam.moving ? "#f2b23a" : "#fff"; s.lineWidth = 2;
  s.strokeRect(sx(cam.pan - fx / 2), sy(cam.tilt + fy / 2), sx(cam.pan + fx / 2) - sx(cam.pan - fx / 2), sy(cam.tilt - fy / 2) - sy(cam.tilt + fy / 2));
  el.querySelector(".pan").textContent = cam.pan.toFixed(1) + "°";
  el.querySelector(".tilt").textContent = cam.tilt.toFixed(1) + "°";
  el.querySelector(".zoom").textContent = cam.zoom.toFixed(1) + "×";
  el.querySelector(".dot").classList.toggle("on", cam.moving);
  el.querySelector(".last").textContent = cam.last + (cam.presets.length ? `  ·  presets: ${cam.presets.join(", ")}` : "");
}
const els = {};
let state = [];
async function poll() {
  try { state = await (await fetch("/state")).json(); } catch (e) {}
  for (const cam of state) {
    if (!els[cam.n]) {
      const d = document.createElement("section"); d.className = "cam";
      d.innerHTML = `<h2><span><i class="dot"></i>Camera ${cam.n}</span><span style="color:var(--muted)">VISCA UDP ${cam.udp} · TCP ${cam.tcp}</span></h2>
        <canvas class="view" width="${W}" height="${H}"></canvas><canvas class="strip" width="480" height="90" style="margin-top:6px"></canvas>
        <div class="hud"><div><span>Pan</span><b class="pan"></b></div><div><span>Tilt</span><b class="tilt"></b></div><div><span>Zoom</span><b class="zoom"></b></div></div>
        <div class="last"></div>`;
      document.getElementById("cams").appendChild(d); els[cam.n] = d;
    }
  }
  setTimeout(poll, 60);
}
function frame(t) { for (const cam of state) if (els[cam.n]) draw(cam, els[cam.n], t); requestAnimationFrame(frame); }
poll(); requestAnimationFrame(frame);
