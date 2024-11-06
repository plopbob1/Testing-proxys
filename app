from flask import Flask, request, Response, render_template
import requests
from requests.exceptions import RequestException
from urllib.parse import urljoin, urlparse
import websocket
from werkzeug.middleware.proxy_fix import ProxyFix
import os
import logging
import gzip
import brotli

app = Flask(__name__)
app.wsgi_app = ProxyFix(app.wsgi_app, x_proto=1)

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def decode_content(content, encoding):
    """Decode content based on Content-Encoding header"""
    try:
        if encoding == 'gzip':
            return gzip.decompress(content)
        elif encoding == 'br':
            return brotli.decompress(content)
        return content
    except Exception as e:
        logger.error(f"Error decoding content: {str(e)}")
        return content

def handle_response_content(resp):
    """Handle response content with proper decoding"""
    try:
        content = resp.content
        content_encoding = resp.headers.get('content-encoding', '').lower()
        decoded_content = decode_content(content, content_encoding)
        content_type = resp.headers.get('content-type', '').lower()
        charset = 'utf-8'
        if 'charset=' in content_type:
            charset = content_type.split('charset=')[-1].split(';')[0]
        if 'text' in content_type or 'json' in content_type or 'javascript' in content_type:
            try:
                return decoded_content.decode(charset)
            except (UnicodeDecodeError, AttributeError):
                return decoded_content
        return decoded_content
    except Exception as e:
        logger.error(f"Error handling response content: {str(e)}")
        return content

def modify_url(url, original_url):
    """Modify relative URLs to absolute URLs"""
    if url.startswith('//'):
        return 'https:' + url
    elif url.startswith('/'):
        parsed_original = urlparse(original_url)
        base = f"{parsed_original.scheme}://{parsed_original.netloc}"
        return urljoin(base, url)
    return url

@app.route('/', defaults={'path': ''})
@app.route('/<path:path>')
def proxy(path):
    target_url = request.args.get('url', '')
    if not target_url:
        target_url = path if path.startswith(('http://', 'https://')) else f'https://{path}'

    logger.info(f"Proxying request to: {target_url}")

    try:
        if request.headers.get('Upgrade') == 'websocket':
            return handle_websocket(target_url)

        headers = {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.5',
            'Accept-Encoding': 'gzip, deflate, br',
            'Connection': 'keep-alive',
            'Upgrade-Insecure-Requests': '1',
            'Sec-Fetch-Dest': 'document',
            'Sec-Fetch-Mode': 'navigate',
            'Sec-Fetch-Site': 'none',
            'Sec-Fetch-User': '?1',
            'Cache-Control': 'no-cache',
            'Pragma': 'no-cache',
        }

        if 'geforcenow.com' in target_url:
            headers.update({
                'Origin': 'https://play.geforcenow.com',
                'Referer': 'https://play.geforcenow.com/',
            })

        resp = requests.request(
            method=request.method,
            url=target_url,
            headers=headers,
            data=request.get_data(),
            cookies=request.cookies,
            allow_redirects=True,
            verify=False
        )

        content = handle_response_content(resp)

        excluded_headers = ['content-encoding', 'content-length', 'transfer-encoding', 'connection', 'host']
        response_headers = [(name, value) for (name, value) in resp.raw.headers.items()
                          if name.lower() not in excluded_headers]

        response_headers.extend([
            ('Access-Control-Allow-Origin', '*'),
            ('Access-Control-Allow-Methods', '*'),
            ('Access-Control-Allow-Headers', '*'),
            ('Access-Control-Allow-Credentials', 'true')
        ])

        response = Response(response=content, status=resp.status_code, headers=response_headers)

        if resp.headers.get('content-type'):
            response.content_type = resp.headers['content-type']

        return response

    except Exception as e:
        logger.error(f"Error proxying request: {str(e)}")
        return str(e), 500

def handle_websocket(url):
    try:
        ws = websocket.create_connection(
            url.replace('https://', 'wss://').replace('http://', 'ws://'),
            header=dict(request.headers)
        )
        
        def on_message(ws, message):
            logger.info(f"WebSocket message received: {message[:100]}...")
            return message

        def on_error(ws, error):
            logger.error(f"WebSocket error: {error}")

        def on_close(ws):
            logger.info("WebSocket connection closed")

        ws.on_message = on_message
        ws.on_error = on_error
        ws.on_close = on_close

        return '', 101

    except Exception as e:
        logger.error(f"Error handling WebSocket connection: {str(e)}")
        return str(e), 500

@app.route('/proxy', methods=['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS'])
def proxy_with_url():
    url = request.args.get('url')
    if not url:
        return 'Missing URL parameter', 400
    return proxy(url)

@app.errorhandler(404)
def not_found(e):
    return render_template('404.html'), 404

@app.errorhandler(500)
def server_error(e):
    return render_template('500.html'), 500

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8080))
    cert_path = os.environ.get('CERT_PATH')
    key_path = os.environ.get('KEY_PATH')
    
    if not os.path.exists('templates'):
        os.makedirs('templates')
        with open('templates/404.html', 'w') as f:
            f.write('<h1>404 - Page Not Found</h1>')
        with open('templates/500.html', 'w') as f:
            f.write('<h1>500 - Server Error</h1>')

    if cert_path and key_path:
        ssl_context = (cert_path, key_path)
        app.run(host='0.0.0.0', port=port, ssl_context=ssl_context, debug=True)
    else:
        app.run(host='0.0.0.0', port=port, debug=True)
