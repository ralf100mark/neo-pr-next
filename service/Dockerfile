# NEO data model service (see neo_model.py). No secrets in the image: all config comes from the environment.
FROM python:3.11-slim
RUN useradd --uid 1000 --create-home neo
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY neo_model.py .
USER neo
ENV PYTHONUNBUFFERED=1
CMD ["python", "neo_model.py"]
