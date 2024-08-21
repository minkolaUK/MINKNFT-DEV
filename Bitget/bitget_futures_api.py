from typing import Optional, Literal
from fastapi import HTTPException
import aiohttp
import asyncio
import time
import hmac
import hashlib
import base64
import json
import os

# Load environment variables
class BitgetClient:
    def __init__(self):
        self.api_key = os.getenv("BITGET_API_KEY")
        self.api_secret_key = os.getenv("BITGET_API_SECRET")
        self.passphrase = os.getenv("BITGET_PASSPHRASE")
        self.api_url = "https://api.bitget.com"

    def generate_signature(self, prehash_string: str) -> str:
        mac = hmac.new(bytes(self.api_secret_key, encoding='utf8'), bytes(prehash_string, encoding='utf-8'), digestmod='sha256')
        return base64.b64encode(mac.digest()).decode()

    def get_headers(self, method: str, request_path: str, query_string: str, body: str) -> dict:
        timestamp = str(int(time.time() * 1000))
        prehash_string = f"{timestamp}{method}{request_path}"
        if query_string:
            prehash_string += f"?{query_string}"
        prehash_string += body
        sign = self.generate_signature(prehash_string)
        return {
            "Content-Type": "application/json",
            "ACCESS-KEY": self.api_key,
            "ACCESS-SIGN": sign,
            "ACCESS-PASSPHRASE": self.passphrase,
            "ACCESS-TIMESTAMP": timestamp,
            "locale": "en-US"
        }

    async def get_positions(self):
        method = "GET"
        request_path = "/api/v2/mix/position/all-position"
        params = {
            "productType": "USDT-FUTURES",
            "marginCoin": "USDT"
        }
        query_string = '&'.join([f"{key}={value}" for key, value in sorted(params.items())])
        url = f"{self.api_url}{request_path}?{query_string}"
        headers = self.get_headers(method, request_path, query_string, "")
        
        async with aiohttp.ClientSession() as session:
            async with session.get(url, headers=headers) as response:
                return await response.json()

    async def get_crypto_price(self, symbol: str) -> float:
        url = f"{self.api_url}/api/v2/mix/market/ticker?productType=USDT-FUTURES&symbol={str.upper(symbol)}USDT"
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(url) as response:
                    data = await response.json()
                    return float(data['data'][0]['indexPrice'])
        except TypeError:
            raise HTTPException(
                status_code=404,
                detail=f"Symbol {symbol} not found"
            )

    async def get_historial_orders(self):
        method = "GET"
        request_path = "/api/v2/mix/order/orders-history"
        params = {
            "productType": "USDT-FUTURES"
        }
        query_string = '&'.join([f"{key}={value}" for key, value in sorted(params.items())])
        url = f"{self.api_url}{request_path}?{query_string}"
        headers = self.get_headers(method, request_path, query_string, "")

        async with aiohttp.ClientSession() as session:
            async with session.get(url, headers=headers) as response:
                return await response.json()

    async def place_plan_order(
        self, symbol: str, size: str, price: str, trigger_price: str,
        side: Literal['buy', 'sell'], margin_mode: str = "isolated", order_type: str = "limit"
    ):
        method = "POST"
        request_path = "/api/v2/mix/order/place-plan-order"
        
        params = {
            "planType": "normal_plan",
            "symbol": symbol + "USDT",
            "productType": "usdt-futures",
            "marginMode": margin_mode,
            "marginCoin": "USDT",
            "size": size,
            "price": price,
            "callbackRatio": "",
            "triggerPrice": trigger_price,
            "triggerType": "mark_price",
            "side": side,
            "tradeSide": "open",
            "orderType": order_type,
            "clientOid": str(int(time.time() * 1000)),  # Unique clientOid
            "reduceOnly": "NO",
            "presetStopSurplusPrice": "",
            "stopSurplusTriggerPrice": "",
            "stopSurplusTriggerType": "",
            "presetStopLossPrice": "",
            "stopLossTriggerPrice": "",
            "stopLossTriggerType": ""
        }

        body = json.dumps(params)
        headers = self.get_headers(method, request_path, "", body)

        async with aiohttp.ClientSession() as session:
            async with session.post(f"{self.api_url}{request_path}", headers=headers, data=body) as response:
                return await response.json()

    async def set_leverage(self, symbol: str, leverage: str):
        method = "POST"
        request_path = "/api/v2/mix/account/set-leverage"
        params = {
            "symbol": symbol,
            "productType": "USDT-FUTURES",
            "marginCoin": "usdt",
            "leverage": leverage
        }
        query_string = '&'.join([f"{key}={value}" for key, value in sorted(params.items())])
        url = f"{self.api_url}{request_path}?{query_string}"
        headers = self.get_headers(method, request_path, query_string, "")

        async with aiohttp.ClientSession() as session:
            async with session.post(url, headers=headers) as response:
                return await response.json()

    async def close_order(self, symbol: str):
        method = "POST"
        request_path = "/api/v2/mix/order/close-positions"
        params = {
            "symbol": symbol + "USDT",
            "productType":"usdt-futures",

        }
        body = json.dumps(params)
        headers = self.get_headers(method, request_path, "", body)

        async with aiohttp.ClientSession() as session:
            async with session.post(f"{self.api_url}{request_path}", headers=headers, data=body) as response:
                return await response.json()

def process_trades(trades_data):
    import pandas as pd
    
    # Convert the JSON data to a pandas DataFrame
    df = pd.json_normalize(trades_data)

    # Ensure 'totalProfits' exists and fill missing values with 0
    if 'totalProfits' in df.columns:
        df['totalProfits'] = df['totalProfits'].fillna(0).astype(float)
    else:
        df['totalProfits'] = 0.0

    # Ensure 'priceAvg' exists
    if 'priceAvg' not in df.columns:
        df['priceAvg'] = None

    # Ensure 'tradeSide' exists
    if 'tradeSide' not in df.columns:
        df['tradeSide'] = None

    # Calculate Position PnL and add necessary columns
    df['Position PnL'] = df['totalProfits']
    df['Avg. entry price'] = df.apply(lambda x: x['priceAvg'] if x['tradeSide'] == 'open' else None, axis=1)
    df['Avg. exit price'] = df.apply(lambda x: x['priceAvg'] if x['tradeSide'] == 'close' else None, axis=1)
    df['Closed quantity'] = df.apply(lambda x: x['size'] if x['tradeSide'] == 'close' else None, axis=1)
    df['Closed value'] = df.apply(lambda x: x['quoteVolume'] if x['tradeSide'] == 'close' else None, axis=1)

    # Filter relevant columns
    filtered_df = df[['symbol', 'cTime', 'Avg. entry price', 'Avg. exit price', 'Closed quantity', 'Closed value', 'Position PnL', 'uTime']]

    # Rename columns to match the screenshot
    filtered_df.columns = ['Futures', 'Open time', 'Avg. entry price', 'Avg. exit price', 'Closed quantity', 'Closed value', 'Position PnL', 'Closed time']

    # Convert timestamps to readable datetime format
    filtered_df['Open time'] = pd.to_datetime(filtered_df['Open time'], unit='ms')
    filtered_df['Closed time'] = pd.to_datetime(filtered_df['Closed time'], unit='ms')

    return filtered_df


# Main execution
if __name__ == "__main__":
    client = BitgetClient()
    
    async def main():
        result = await client.get_historial_orders()
        print(process_trades(result))
        # Example of placing a plan order
        # result = await client.place_plan_order(symbol="BTC", size="0.01", price="24000", trigger_price="24100", side="buy")
        # print(result)
      
    asyncio.run(main())
