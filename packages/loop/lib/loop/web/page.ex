defmodule Loop.Web.Page do
  @moduledoc false

  @html """
  <!doctype html>
  <html lang="en"><head>
  <meta charset="utf-8">
  <title>loop</title>
  <style>
    body{margin:0;background:#0b0b0e;color:#cfd0d3;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:13px}
    header{padding:8px 14px;border-bottom:1px solid #23252b;display:flex;justify-content:space-between;align-items:center}
    header b{color:#e8e9eb}
    #status{color:#7b7d83}
    #log{white-space:pre-wrap;padding:10px 14px;height:calc(100vh - 42px);overflow-y:auto}
    .halt{color:#ff7a7a}
    .sep{color:#8aa9ff}
  </style></head><body>
  <header><b>loop</b><span id="status">connecting…</span></header>
  <div id="log"></div>
  <script>
    const log=document.getElementById('log');
    const status=document.getElementById('status');
    function connect(){
      const proto=location.protocol==='https:'?'wss:':'ws:';
      const ws=new WebSocket(proto+'//'+location.host+'/ws');
      ws.onopen=()=>status.textContent='live';
      ws.onclose=()=>{status.textContent='disconnected — retrying';setTimeout(connect,1500)};
      ws.onmessage=e=>{
        const line=document.createElement('div');
        line.textContent=e.data;
        if(e.data.startsWith('HALT:'))line.className='halt';
        else if(e.data.startsWith('──'))line.className='sep';
        log.appendChild(line);
        log.scrollTop=log.scrollHeight;
      };
    }
    connect();
  </script></body></html>
  """

  def render, do: @html
end
