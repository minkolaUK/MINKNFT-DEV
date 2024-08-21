from flask import Flask, request, jsonify
import asyncio
from bitget_client import BitgetClient  # Make sure this path matches where your Bitget client is located

app = Flask(__name__)
client = BitgetClient()  # Initialize the Bitget client

@app.route('/webhook', methods=['POST'])
def handle_webhook():
    try:
        # Parse the incoming webhook data
        data = request.json
        symbol = data['symbol']
        strategy = data['strategy']
        amount = data.get('amount', '1')  # Default to 1 if not provided

        # Determine action based on strategy
        if strategy == "buy":
            asyncio.run(client.open_order_futures(symbol=symbol, amount=amount, mode='Buy'))
        elif strategy == "sell":
            asyncio.run(client.open_order_futures(symbol=symbol, amount=amount, mode='Sell'))
        elif strategy == "close":
            asyncio.run(client.close_order(symbol=symbol))
        else:
            return jsonify({"error": "Invalid strategy"}), 400

        return jsonify({"status": "success", "strategy": strategy, "symbol": symbol, "amount": amount})

    except Exception as e:
        return jsonify({"error": str(e), "traceback": traceback.format_exc()}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5002)
