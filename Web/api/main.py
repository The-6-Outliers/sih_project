from collections import Counter
import io
import re

import numpy as np
import pandas as pd
import pytesseract
from fastapi import FastAPI, File, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from PIL import Image

app = FastAPI(title='SIH Smart Governance AI Service', version='0.1.0')
app.add_middleware(CORSMiddleware, allow_origins=['http://localhost:5173'], allow_methods=['*'], allow_headers=['*'])

@app.post('/api/ocr')
async def extract_form(file: UploadFile = File(...)):
    content = await file.read()
    text = pytesseract.image_to_string(Image.open(io.BytesIO(content)))
    pm10 = re.search(r'PM\s*10\s*[:=-]?\s*(\d+(?:\.\d+)?)', text, re.I)
    methane = re.search(r'methane\s*[:=-]?\s*(\d+(?:\.\d+)?)', text, re.I)
    return {'filename': file.filename, 'text': text, 'metrics': {'pm10': float(pm10.group(1)) if pm10 else None, 'methane': float(methane.group(1)) if methane else None}}

@app.post('/api/predict-risk')
async def predict_risk(payload: dict):
    logs = payload.get('logs', payload.get('inspections', []))
    frame = pd.DataFrame(logs)
    if frame.empty:
        return {'riskIndex': 0, 'flags': [], 'message': 'No inspection history supplied.'}
    statuses = frame.get('status', pd.Series(dtype=str)).fillna('').str.lower()
    violations = int(statuses.eq('violation').sum())
    pending = int(statuses.eq('pending').sum())
    scores = pd.to_numeric(frame.get('automatedRiskScore', pd.Series(dtype=float)), errors='coerce').dropna()
    baseline = float(scores.mean()) if not scores.empty else violations / max(len(frame), 1) * 100
    risk_index = int(np.clip(np.mean([baseline, violations / max(len(frame), 1) * 100 + pending * 3]), 0, 100))
    categories = Counter(frame.get('category', pd.Series(dtype=str)).dropna().tolist())
    flags = [f'Repeated {category} observations' for category, count in categories.items() if count >= 3]
    if violations >= 3:
        flags.append('Violation frequency above operating baseline')
    return {'riskIndex': risk_index, 'flags': flags, 'highRisk': risk_index >= 70, 'sampleSize': len(frame)}
