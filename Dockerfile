FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN pip install --no-cache-dir -e .

RUN mkdir -p data_store/db data_store/cache logs

EXPOSE 8501

# Par défaut, lance le dashboard Streamlit. Peut être surchargé pour lancer
# scripts/run_backtest.py, scripts/run_paper_trading.py ou scripts/fetch_data.py.
CMD ["streamlit", "run", "src/polyquant/dashboard/app.py", "--server.address=0.0.0.0", "--server.port=8501"]
