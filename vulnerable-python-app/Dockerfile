FROM python:3.11-slim

WORKDIR /app

# Copy requirements first for better caching
COPY webapp/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the app code
COPY webapp/ .

# Run as root for security training (K8s Risk)
USER root

EXPOSE 8080

CMD ["python", "app.py"]
