from flask import Flask, request, render_template_string
import subprocess
import os
import time

app = Flask(__name__)

HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>Python Vulnerable App - peachycloudsecurity.com</title>
    <style>
        body { font-family: sans-serif; margin: 40px; background: #fafafa; }
        .container { max-width: 800px; margin: auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #d32f2f; }
        pre { background: #263238; color: #fff; padding: 15px; border-radius: 4px; }
        button { padding: 10px 20px; background: #d32f2f; color: white; border: none; cursor: pointer; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔓 Python Vulnerable App</h1>
        <p>By <a href="https://peachycloudsecurity.com">peachycloudsecurity.com</a></p>
        <form method="POST" action="/ping">
            <input type="text" name="host" placeholder="127.0.0.1" style="padding:10px; width:250px;">
            <button type="submit">Ping</button>
        </form>
        {% if result %}<pre>{{ result }}</pre>{% endif %}
        <br><a href="/info">System Info</a>
    </div>
</body>
</html>
"""

@app.before_request
def log_request():
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {request.method} {request.path}")

@app.route('/')
def index():
    return render_template_string(HTML_TEMPLATE)

@app.route('/ping', methods=['POST'])
def ping():
    host = request.form.get('host', '')
    try:
        cmd = f"ping -c 3 {host}"
        result = subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT, text=True, timeout=5)
    except Exception as e:
        result = str(e)
    return render_template_string(HTML_TEMPLATE, host=host, result=result)

@app.route('/info')
def info():
    return f"Hostname: {os.uname().nodename} | UID: {os.getuid()}"

@app.route('/healthz')
def healthz():
    return "OK", 200

@app.route('/readyz')
def readyz():
    return "OK", 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
