(function () {
  var canvas = document.getElementById('bees-rain');
  if (!canvas || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  var ctx = canvas.getContext('2d');
  var hero = canvas.parentElement;
  var hex = 14;
  var cells = [];
  var links = [];
  var t = 0;

  function hexPath(x, y, r) {
    ctx.beginPath();
    for (var i = 0; i < 6; i++) {
      var a = (Math.PI / 3) * i - Math.PI / 6;
      var px = x + r * Math.cos(a);
      var py = y + r * Math.sin(a);
      if (i === 0) ctx.moveTo(px, py);
      else ctx.lineTo(px, py);
    }
    ctx.closePath();
  }

  function size() {
    var rect = hero.getBoundingClientRect();
    canvas.width = rect.width;
    canvas.height = rect.height;
    cells = [];
    var dx = hex * 1.75;
    var dy = hex * 1.55;
    for (var row = 0; row < canvas.height / dy + 2; row++) {
      for (var col = 0; col < canvas.width / dx + 2; col++) {
        var x = col * dx + (row % 2 ? dx / 2 : 0);
        var y = row * dy;
        if (Math.random() > 0.62) {
          cells.push({
            x: x,
            y: y,
            phase: Math.random() * Math.PI * 2,
            twin: Math.random() > 0.82
          });
        }
      }
    }
    links = [];
    for (var i = 0; i < cells.length; i++) {
      if (!cells[i].twin) continue;
      var best = -1;
      var bestD = 90;
      for (var j = 0; j < cells.length; j++) {
        if (i === j || !cells[j].twin) continue;
        var d = Math.hypot(cells[i].x - cells[j].x, cells[i].y - cells[j].y);
        if (d > 24 && d < bestD) {
          bestD = d;
          best = j;
        }
      }
      if (best >= 0) links.push([i, best]);
    }
  }

  size();
  window.addEventListener('resize', size);

  function frame() {
    t += 0.018;
    ctx.fillStyle = 'rgba(12, 16, 14, 0.22)';
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    for (var L = 0; L < links.length; L++) {
      var a = cells[links[L][0]];
      var b = cells[links[L][1]];
      var pulse = 0.15 + 0.25 * (0.5 + 0.5 * Math.sin(t * 1.4 + a.phase));
      ctx.strokeStyle = 'rgba(61, 202, 160,' + pulse + ')';
      ctx.lineWidth = 1;
      ctx.setLineDash([3, 5]);
      ctx.beginPath();
      ctx.moveTo(a.x, a.y);
      ctx.lineTo(b.x, b.y);
      ctx.stroke();
      ctx.setLineDash([]);
    }

    for (var i = 0; i < cells.length; i++) {
      var c = cells[i];
      var glow = 0.18 + 0.35 * (0.5 + 0.5 * Math.sin(t + c.phase));
      hexPath(c.x, c.y, hex * 0.42);
      if (c.twin) {
        ctx.fillStyle = 'rgba(61, 202, 160,' + (0.12 + glow * 0.35) + ')';
        ctx.strokeStyle = 'rgba(61, 202, 160,' + (0.35 + glow * 0.4) + ')';
      } else {
        ctx.fillStyle = 'rgba(232, 184, 74,' + (0.04 + glow * 0.12) + ')';
        ctx.strokeStyle = 'rgba(232, 184, 74,' + (0.18 + glow * 0.25) + ')';
      }
      ctx.fill();
      ctx.lineWidth = 1;
      ctx.stroke();
    }

    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
})();
