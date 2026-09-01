const $ = (selector) => document.querySelector(selector);
const fileInput = $('#fileInput');
const dropZone = $('#dropZone');
const preview = $('#preview');
const dropPrompt = $('#dropPrompt');
const fileMeta = $('#fileMeta');
const inferButton = $('#inferButton');
const confidence = $('#confidence');
const confidenceValue = $('#confidenceValue');
const errorBox = $('#errorBox');
let selectedFile = null;

function bytes(value) {
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KiB`;
  return `${(value / 1024 / 1024).toFixed(2)} MiB`;
}

function ms(value) { return `${Number(value).toFixed(3)} ms`; }

function setBusy(busy) {
  inferButton.disabled = busy || !selectedFile;
  inferButton.querySelector('.button-label').textContent = busy ? '开发板正在推理…' : '发送到开发板并推理';
  inferButton.querySelector('.spinner').hidden = !busy;
}

function selectFile(file) {
  if (!file) return;
  selectedFile = file;
  preview.src = URL.createObjectURL(file);
  preview.hidden = false;
  dropPrompt.hidden = true;
  fileMeta.textContent = `${file.name} · ${bytes(file.size)} · ${file.type || 'unknown type'}`;
  errorBox.hidden = true;
  setBusy(false);
}

dropZone.addEventListener('click', () => fileInput.click());
fileInput.addEventListener('change', () => selectFile(fileInput.files[0]));
['dragenter', 'dragover'].forEach(name => dropZone.addEventListener(name, (event) => {
  event.preventDefault(); dropZone.classList.add('dragging');
}));
['dragleave', 'drop'].forEach(name => dropZone.addEventListener(name, (event) => {
  event.preventDefault(); dropZone.classList.remove('dragging');
}));
dropZone.addEventListener('drop', event => selectFile(event.dataTransfer.files[0]));
confidence.addEventListener('input', () => { confidenceValue.textContent = Number(confidence.value).toFixed(2); });

async function status(probe = false) {
  const dot = $('#statusDot'); const text = $('#statusText');
  text.textContent = probe ? '探测开发板…' : '检查环境…';
  dot.className = 'status-dot';
  try {
    const response = await fetch(`/api/status${probe ? '?probe=1' : ''}`);
    const data = await response.json();
    if (!response.ok || !data.local_ready) throw new Error(data.error || '本地artifact未就绪');
    dot.classList.add(data.board.reachable === false ? 'bad' : 'ready');
    text.textContent = data.board.reachable === false ? '开发板未连接' : (data.busy ? '开发板忙' : '环境已就绪');
  } catch (error) {
    dot.classList.add('bad'); text.textContent = '环境异常';
  }
}
$('#statusButton').addEventListener('click', () => status(true));

function renderBars(target, values) {
  const entries = Object.entries(values).filter(([, value]) => Number(value) > 0);
  const max = Math.max(...entries.map(([, value]) => Number(value)), 0.001);
  target.innerHTML = entries.map(([name, value]) => `
    <div class="bar-row"><span title="${name}">${name}</span>
      <progress class="bar-track" max="${max}" value="${Number(value)}"></progress>
      <strong>${Number(value).toFixed(3)} ms</strong></div>`).join('');
}

function showResult(data) {
  const image = $('#resultImage');
  image.src = `${data.artifacts.visualization_url}?v=${Date.now()}`;
  image.hidden = false; $('#resultPlaceholder').hidden = true;
  $('#resultSubtitle').textContent = `${data.detections.length}个检测 · ${data.profile} · image_id ${data.image.image_id}`;
  const grouped = new Map();
  for (const item of data.detections) {
    const previous = grouped.get(item.class_name) || {count: 0, best: 0};
    previous.count += 1; previous.best = Math.max(previous.best, item.score); grouped.set(item.class_name, previous);
  }
  const summary = $('#detectionSummary');
  summary.innerHTML = [...grouped.entries()].map(([name, value]) =>
    `<span class="detection-pill">${name} ×${value.count}<b>${value.best.toFixed(3)}</b></span>`).join('') ||
    '<span class="detection-pill">未发现超过阈值的目标</span>';
  summary.hidden = false;

  const t = data.timing;
  const metrics = [
    ['Resident', t.resident_ms, true], ['PL卷积', t.pl_ms, false], ['A53总计', t.a53_ms, false],
    ['Decode/NMS', t.decode_ms, false], ['主机单次会话', t.host.network_session_ms, false],
  ];
  $('#metricCards').innerHTML = metrics.map(([name, value, primary]) =>
    `<div class="metric ${primary ? 'primary-metric' : ''}"><span>${name}</span><b>${ms(value)}</b></div>`).join('');
  renderBars($('#plBars'), t.pl_layers_ms);
  renderBars($('#a53Bars'), {...t.a53_ops_ms, candidate: t.candidate_ms, sort: t.sort_ms, nms: t.nms_ms});
  $('#evidence').innerHTML = [
    ['请求ID', data.request_id], ['输出CRC32', t.output_crc32],
    ['板卡温度', `${t.transport.board_current_temp_c.toFixed(2)} °C`],
    ['输入/返回', `${bytes(t.transport.input_bytes)} / ${bytes(t.transport.result_bytes)}`],
    ['Runner binding', data.artifacts.runner_binding_sha256],
    ['可视化SHA256', data.artifacts.visualization_sha256],
    ['输入index SHA256', data.artifacts.input_index_sha256],
    ['板端结果SHA256', data.artifacts.board_output_sha256],
  ].map(([key, value]) => `<div><b>${key}</b><br>${value}</div>`).join('');
  $('#metricsSection').hidden = false;
  $('#metricsSection').scrollIntoView({behavior: 'smooth', block: 'start'});
}

inferButton.addEventListener('click', async () => {
  if (!selectedFile) return;
  setBusy(true); errorBox.hidden = true;
  const profile = document.querySelector('input[name="profile"]:checked').value;
  try {
    const response = await fetch('/api/infer', {
      method: 'POST', body: selectedFile,
      headers: {
        'Content-Type': selectedFile.type || 'application/octet-stream',
        'X-File-Name': encodeURIComponent(selectedFile.name),
        'X-Decode-Profile': profile,
        'X-Display-Confidence': Number(confidence.value).toFixed(2),
      },
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
    showResult(data); status(false);
  } catch (error) {
    errorBox.textContent = error.message; errorBox.hidden = false;
  } finally { setBusy(false); }
});

status(false);
