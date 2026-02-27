/**
 * app.js — Main application: MediaPipe face capture + Three.js 3D viewer + timeline.
 *
 * ULTRA-REALISTIC 3D FACE SCAN TECHNOLOGY:
 * - High-resolution camera capture (1920×1080)
 * - Multi-frame landmark averaging (8 frames) for stability
 * - IPD-calibrated 3D coordinates for accurate facial proportions
 * - 2-level mesh subdivision (~468 → ~2000 → ~8000 vertices)
 * - HC Laplacian smoothing (feature-preserving — keeps nose bridge & nostrils)
 * - Capped deformation to prevent vertex collapse at high swelling
 * - MeshPhysicalMaterial with skin-like sheen & clearcoat rendering
 * - Environment-quality multi-directional lighting
 */

import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

// ═══════════════════════════════════════════════════════════════════════════
// GLOBALS
// ═══════════════════════════════════════════════════════════════════════════

let faceLandmarker = null;
let camera = null;
let videoStream = null;

// Captured data
let capturedLandmarks = null;
let zoneWeights = null;

// Multi-frame averaging for stable landmarks
let landmarkBuffer = [];
const FRAME_BUFFER_SIZE = 8;

// Three.js
let scene, threeCamera, renderer, controls;
let faceMesh = null;
let baseLandmarks = null;
let faceNormals = null;
let triangleIndices = null;

// Face texture from camera
let capturedTexture = null;
let capturedUVs = null;

// Face scale (calibrated, used for displacement capping)
let faceScale = 0.14;

// Delaunay triangulation library (loaded async from CDN)
let Delaunator = null;

// Default zone weight — defensive fallback for null/undefined entries
const DEFAULT_WEIGHT = Object.freeze({
    zone: 'none', weight: 0, color: [0.15, 0.15, 0.15], isBruiseZone: false
});

// Model
let healingModel = new HealingModelJS.HealingModel();
let currentDay = 0;

// UI state
let currentScreen = 'splash';
let showZones = false;

// ═══════════════════════════════════════════════════════════════════════════
// MEDIAPIPE FACE LANDMARKER SETUP
// ═══════════════════════════════════════════════════════════════════════════

async function initMediaPipe() {
    const statusEl = document.getElementById('loading-status');
    statusEl.textContent = 'Loading face detection model...';

    // Load Delaunator in parallel for robust triangulation
    loadDelaunator();

    try {
        const vision = await import('https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.18/vision_bundle.mjs');
        const { FaceLandmarker, FilesetResolver } = vision;

        const filesetResolver = await FilesetResolver.forVisionTasks(
            'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.18/wasm'
        );

        faceLandmarker = await FaceLandmarker.createFromOptions(filesetResolver, {
            baseOptions: {
                modelAssetPath: 'https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task',
                delegate: 'GPU'
            },
            runningMode: 'VIDEO',
            numFaces: 1,
            outputFacialTransformationMatrixes: true,
            outputFaceBlendshapes: false,
        });

        // Extract tessellation for mesh building (check both spellings)
        const tessData = FaceLandmarker.FACE_LANDMARKS_TESSELATION
                      || FaceLandmarker.FACE_LANDMARKS_TESSELLATION;
        if (tessData && tessData.length > 0) {
            buildTrianglesFromEdges(tessData);
            console.log(`[MediaPipe] Tessellation: ${tessData.length} edges → ${triangleIndices ? triangleIndices.length / 3 : 0} triangles`);
        } else {
            console.warn('[MediaPipe] No tessellation data — will use fallback');
        }

        statusEl.textContent = 'Ready!';
        document.getElementById('start-btn').disabled = false;
    } catch (err) {
        console.error('[MediaPipe] Init failed:', err);
        statusEl.textContent = 'Failed to load model. Check internet connection.';
    }
}

/**
 * Convert FACE_LANDMARKS_TESSELATION edges into triangle indices.
 */
function buildTrianglesFromEdges(edges) {
    const adj = new Map();
    for (const { start, end } of edges) {
        if (!adj.has(start)) adj.set(start, new Set());
        if (!adj.has(end)) adj.set(end, new Set());
        adj.get(start).add(end);
        adj.get(end).add(start);
    }

    const seen = new Set();
    const tris = [];

    for (const { start: a, end: b } of edges) {
        const nA = adj.get(a);
        const nB = adj.get(b);
        if (!nA || !nB) continue;

        for (const c of nA) {
            if (nB.has(c)) {
                const tri = [a, b, c].sort((x, y) => x - y);
                const key = `${tri[0]},${tri[1]},${tri[2]}`;
                if (!seen.has(key)) {
                    seen.add(key);
                    tris.push(tri[0], tri[1], tri[2]);
                }
            }
        }
    }

    triangleIndices = new Uint32Array(tris);
    console.log(`[Mesh] ${tris.length / 3} triangles from ${edges.length} edges`);
}

// ═══════════════════════════════════════════════════════════════════════════
// CAMERA + FACE TRACKING
// ═══════════════════════════════════════════════════════════════════════════

async function startCamera() {
    const video = document.getElementById('camera-video');
    const canvas = document.getElementById('camera-overlay');
    const ctx = canvas.getContext('2d');
    const instructionEl = document.getElementById('scan-instruction');

    if (!window.isSecureContext || !navigator.mediaDevices) {
        showCameraError(instructionEl, 'Camera requires HTTPS. Use localhost or enable HTTPS.');
        return;
    }

    try {
        // HIGH RESOLUTION capture for better texture quality
        videoStream = await navigator.mediaDevices.getUserMedia({
            video: { facingMode: 'user', width: { ideal: 1920 }, height: { ideal: 1080 } }
        });
        video.srcObject = videoStream;
        await video.play();

        canvas.width = video.videoWidth;
        canvas.height = video.videoHeight;
        console.log(`[Camera] Resolution: ${video.videoWidth}×${video.videoHeight}`);

        // Reset frame buffer for multi-frame averaging
        landmarkBuffer = [];

        detectLoop(video, canvas, ctx);
    } catch (err) {
        console.error('[Camera]', err);
        if (err.name === 'NotAllowedError') {
            showCameraError(instructionEl, 'Camera access denied. Please allow camera in browser settings.');
        } else if (err.name === 'NotFoundError') {
            showCameraError(instructionEl, 'No camera found on this device.');
        } else if (err.name === 'NotReadableError') {
            showCameraError(instructionEl, 'Camera is in use by another app.');
        } else {
            showCameraError(instructionEl, 'Camera error: ' + (err.message || err.name));
        }
    }
}

function showCameraError(instructionEl, message) {
    const bottomEl = document.querySelector('.scan-bottom');
    instructionEl.textContent = message;
    document.getElementById('capture-btn').style.display = 'none';

    if (!document.getElementById('camera-fallback-btn')) {
        const fallbackBtn = document.createElement('button');
        fallbackBtn.id = 'camera-fallback-btn';
        fallbackBtn.className = 'btn-primary';
        fallbackBtn.textContent = 'Use Demo Mode Instead';
        fallbackBtn.style.maxWidth = '260px';
        fallbackBtn.addEventListener('click', () => {
            if (videoStream) { videoStream.getTracks().forEach(t => t.stop()); videoStream = null; }
            useSampleFace();
        });
        bottomEl.appendChild(fallbackBtn);
    }
}

function detectLoop(video, canvas, ctx) {
    if (currentScreen !== 'scan') return;

    if (faceLandmarker && video.readyState >= 2) {
        const results = faceLandmarker.detectForVideo(video, performance.now());
        ctx.clearRect(0, 0, canvas.width, canvas.height);

        if (results.faceLandmarks && results.faceLandmarks.length > 0) {
            const landmarks = results.faceLandmarks[0];
            drawLandmarks(ctx, landmarks, canvas.width, canvas.height);
            updateTrackingUI(true);
            capturedLandmarks = landmarks;

            // Buffer frames for multi-frame averaging (deep copy)
            landmarkBuffer.push(landmarks.map(lm => ({ x: lm.x, y: lm.y, z: lm.z })));
            if (landmarkBuffer.length > FRAME_BUFFER_SIZE) landmarkBuffer.shift();
        } else {
            updateTrackingUI(false);
            capturedLandmarks = null;
            landmarkBuffer = [];  // Reset on face lost
        }
    }

    requestAnimationFrame(() => detectLoop(video, canvas, ctx));
}

function drawLandmarks(ctx, landmarks, w, h) {
    const noseSet = FaceZones.ALL_NOSE_LANDMARKS;
    const landmarkMap = FaceZones.buildLandmarkMap();

    for (let i = 0; i < landmarks.length; i++) {
        const lm = landmarks[i];
        const x = lm.x * w;
        const y = lm.y * h;

        const zoneInfo = landmarkMap.get(i);
        let color = 'rgba(255,255,255,0.25)';
        let radius = 1;

        if (noseSet.has(i)) {
            if (zoneInfo) {
                const [r, g, b] = zoneInfo.color;
                color = `rgba(${Math.round(r*255)},${Math.round(g*255)},${Math.round(b*255)},0.9)`;
                radius = 2.5;
            } else {
                color = 'rgba(255,200,0,0.7)';
                radius = 2;
            }
        } else if (zoneInfo && zoneInfo.isBruiseZone) {
            const [r, g, b] = zoneInfo.color;
            color = `rgba(${Math.round(r*255)},${Math.round(g*255)},${Math.round(b*255)},0.6)`;
            radius = 1.5;
        }

        ctx.beginPath();
        ctx.arc(x, y, radius, 0, Math.PI * 2);
        ctx.fillStyle = color;
        ctx.fill();
    }

    // Nose tip crosshair
    const tip = landmarks[1];
    ctx.strokeStyle = '#ff3333';
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(tip.x * w - 8, tip.y * h); ctx.lineTo(tip.x * w + 8, tip.y * h);
    ctx.moveTo(tip.x * w, tip.y * h - 8); ctx.lineTo(tip.x * w, tip.y * h + 8);
    ctx.stroke();
}

let stableFrames = 0;
function updateTrackingUI(detected) {
    const instructionEl = document.getElementById('scan-instruction');
    const guideEl = document.getElementById('face-guide');
    const captureBtn = document.getElementById('capture-btn');

    if (detected) {
        stableFrames++;
        if (stableFrames > 20) {
            instructionEl.textContent = 'Hold still...';
            guideEl.classList.add('ready');
            guideEl.classList.remove('tracking');
            captureBtn.disabled = false;
        } else {
            instructionEl.textContent = 'Aligning... keep steady';
            guideEl.classList.add('tracking');
            guideEl.classList.remove('ready');
            captureBtn.disabled = true;
        }
    } else {
        stableFrames = 0;
        instructionEl.textContent = 'Position your face in the frame';
        guideEl.classList.remove('ready', 'tracking');
        captureBtn.disabled = true;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MULTI-FRAME AVERAGING + IPD CALIBRATION
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Average multiple frames of landmark detections for stable, noise-free positions.
 * Reduces jitter from single-frame detection artifacts.
 */
function averageLandmarks(buffer) {
    if (!buffer || buffer.length === 0) return null;
    if (buffer.length === 1) return buffer[0].map(lm => ({ ...lm }));

    const N = buffer[0].length;
    const result = [];

    for (let i = 0; i < N; i++) {
        let sx = 0, sy = 0, sz = 0;
        for (const frame of buffer) {
            sx += frame[i].x;
            sy += frame[i].y;
            sz += frame[i].z;
        }
        const c = buffer.length;
        result.push({ x: sx / c, y: sy / c, z: sz / c });
    }

    return result;
}

/**
 * Convert normalized MediaPipe landmarks to calibrated 3D coordinates.
 * Uses interpupillary distance (IPD) for anatomically accurate proportions.
 *
 * MediaPipe z-coordinate: depth relative to face center, same scale as x/y.
 * Calibration ensures nose protrusion, head shape, and overall proportions
 * match real-world facial geometry (~63mm IPD, ~140mm face width).
 */
function calibrateLandmarksTo3D(landmarks) {
    // ── Key reference points for face geometry ──
    const leftEyeInner = landmarks[133];   // left medial canthus
    const rightEyeInner = landmarks[362];  // right medial canthus
    const leftEyeOuter = landmarks[33];    // left lateral canthus
    const rightEyeOuter = landmarks[263];  // right lateral canthus
    const noseTip = landmarks[1];
    const chin = landmarks[152];
    const forehead = landmarks[10];

    // ── Compute IPD (inter-pupillary distance proxy) ──
    // Average of inner and outer eye centers for each eye
    const leftEyeCenter = {
        x: (leftEyeInner.x + leftEyeOuter.x) / 2,
        y: (leftEyeInner.y + leftEyeOuter.y) / 2,
    };
    const rightEyeCenter = {
        x: (rightEyeInner.x + rightEyeOuter.x) / 2,
        y: (rightEyeInner.y + rightEyeOuter.y) / 2,
    };

    const ipdNorm = Math.sqrt(
        (rightEyeCenter.x - leftEyeCenter.x) ** 2 +
        (rightEyeCenter.y - leftEyeCenter.y) ** 2
    );

    // ── Face center: midpoint between eyes, vertically centered ──
    const centerX = (leftEyeInner.x + rightEyeInner.x) / 2;
    const centerY = (forehead.y + chin.y) / 2;

    // ── Scale calibration ──
    // Real human IPD ≈ 63mm. We model in units where 1 unit = 1m.
    // So IPD = 0.063 in model space.
    const targetIPD = 0.063;
    const scale = targetIPD / Math.max(ipdNorm, 0.02);

    // Store calibrated face width for displacement calculations
    // Real face width ≈ 2.2 × IPD
    faceScale = targetIPD * 2.2; // ~0.139

    // ── Z depth calibration ──
    // MediaPipe z is relative to face width in image space.
    // For accurate depth, we scale z proportionally but with slight boost
    // to preserve nose protrusion (typically 20–25mm, ~35% of IPD).
    const zScale = scale * 1.2;

    // ── Convert all landmarks ──
    const calibrated = landmarks.map(lm => ({
        x: (lm.x - centerX) * scale,
        y: -(lm.y - centerY) * scale,
        z: -lm.z * zScale
    }));

    console.log(`[Calibrate] IPD=${(ipdNorm * 1000).toFixed(1)}px norm, scale=${scale.toFixed(3)}, faceWidth=${(faceScale * 1000).toFixed(1)}mm`);

    return calibrated;
}

// ═══════════════════════════════════════════════════════════════════════════
// MESH SUBDIVISION + SMOOTHING
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Subdivide a triangle mesh by splitting each triangle into 4.
 * Creates midpoint vertices on each edge with interpolated UVs and weights.
 * Result: ~4× triangles, ~2× vertices → much smoother surface.
 */
function subdivideMesh(landmarks, indices, uvData, weights) {
    const edgeMap = new Map();
    const newLandmarks = landmarks.map(lm => ({ ...lm }));
    const newUVs = uvData ? uvData.map(uv => ({ ...uv })) : null;
    const newWeights = weights.map(w => {
        if (!w) return { ...DEFAULT_WEIGHT };
        return { ...w, color: Array.isArray(w.color) ? [...w.color] : [0.15, 0.15, 0.15] };
    });
    const newIndices = [];

    function getMidpoint(i0, i1) {
        const key = `${Math.min(i0, i1)},${Math.max(i0, i1)}`;
        if (edgeMap.has(key)) return edgeMap.get(key);

        const idx = newLandmarks.length;
        const l0 = landmarks[i0], l1 = landmarks[i1];

        // Interpolate position
        newLandmarks.push({
            x: (l0.x + l1.x) / 2,
            y: (l0.y + l1.y) / 2,
            z: (l0.z + l1.z) / 2,
        });

        // Interpolate UV
        if (newUVs && uvData[i0] && uvData[i1]) {
            newUVs.push({
                u: (uvData[i0].u + uvData[i1].u) / 2,
                v: (uvData[i0].v + uvData[i1].v) / 2,
            });
        } else if (newUVs) {
            newUVs.push({ u: 0.5, v: 0.5 });
        }

        // Interpolate zone weight (with defensive null guards)
        const w0 = weights[i0] || DEFAULT_WEIGHT;
        const w1 = weights[i1] || DEFAULT_WEIGHT;
        const c0 = Array.isArray(w0.color) ? w0.color : [0.15, 0.15, 0.15];
        const c1 = Array.isArray(w1.color) ? w1.color : [0.15, 0.15, 0.15];
        newWeights.push({
            zone: (w0.weight || 0) >= (w1.weight || 0) ? w0.zone : w1.zone,
            weight: ((w0.weight || 0) + (w1.weight || 0)) / 2,
            color: [
                (c0[0] + c1[0]) / 2,
                (c0[1] + c1[1]) / 2,
                (c0[2] + c1[2]) / 2,
            ],
            isBruiseZone: !!(w0.isBruiseZone || w1.isBruiseZone),
        });

        edgeMap.set(key, idx);
        return idx;
    }

    for (let t = 0; t < indices.length; t += 3) {
        const i0 = indices[t], i1 = indices[t + 1], i2 = indices[t + 2];
        if (i0 >= landmarks.length || i1 >= landmarks.length || i2 >= landmarks.length) continue;

        const m01 = getMidpoint(i0, i1);
        const m12 = getMidpoint(i1, i2);
        const m02 = getMidpoint(i0, i2);

        newIndices.push(i0, m01, m02);
        newIndices.push(m01, i1, m12);
        newIndices.push(m02, m12, i2);
        newIndices.push(m01, m12, m02);
    }

    console.log(`[Subdivide] ${landmarks.length} → ${newLandmarks.length} vertices, ${indices.length / 3} → ${newIndices.length / 3} triangles`);

    return {
        landmarks: newLandmarks,
        indices: new Uint32Array(newIndices),
        uvs: newUVs,
        weights: newWeights,
    };
}

/**
 * Build vertex adjacency map from triangle indices.
 */
function buildAdjacency(vertexCount, indices) {
    const adj = new Map();
    for (let i = 0; i < vertexCount; i++) adj.set(i, new Set());

    for (let t = 0; t < indices.length; t += 3) {
        const v0 = indices[t], v1 = indices[t + 1], v2 = indices[t + 2];
        if (v0 < vertexCount && v1 < vertexCount && v2 < vertexCount) {
            adj.get(v0).add(v1); adj.get(v0).add(v2);
            adj.get(v1).add(v0); adj.get(v1).add(v2);
            adj.get(v2).add(v0); adj.get(v2).add(v1);
        }
    }

    return adj;
}

/**
 * HC Laplacian smoothing — feature-preserving smoothing algorithm.
 *
 * Unlike standard Laplacian which over-smooths and shrinks features (flattening
 * the nose, filling eye sockets), HC Laplacian pulls smoothed vertices back
 * toward their original positions, preserving sharp features and volume.
 *
 * @param {Array} landmarks - Vertex positions [{x,y,z}]
 * @param {Uint32Array} indices - Triangle indices
 * @param {number} iterations - Number of smoothing passes (2-4 recommended)
 * @param {number} alpha - Original position weight (0-1). Higher = more preservation.
 * @param {number} beta - Correction strength (0-1). Higher = more feature preservation.
 */
function smoothMeshHC(landmarks, indices, iterations = 3, alpha = 0.5, beta = 0.6) {
    const adj = buildAdjacency(landmarks.length, indices);

    let current = landmarks.map(lm => ({ ...lm }));
    const original = landmarks;

    for (let iter = 0; iter < iterations; iter++) {
        // Step 1: Standard Laplacian smooth (move toward neighbor average)
        const smoothed = current.map((lm, i) => {
            const neighbors = adj.get(i);
            if (!neighbors || neighbors.size === 0) return { ...lm };

            let sx = 0, sy = 0, sz = 0;
            for (const n of neighbors) {
                sx += current[n].x; sy += current[n].y; sz += current[n].z;
            }
            const c = neighbors.size;
            return { x: sx / c, y: sy / c, z: sz / c };
        });

        // Step 2: Compute displacement vectors (b) from weighted original
        const bVectors = smoothed.map((lm, i) => ({
            x: lm.x - (alpha * original[i].x + (1 - alpha) * current[i].x),
            y: lm.y - (alpha * original[i].y + (1 - alpha) * current[i].y),
            z: lm.z - (alpha * original[i].z + (1 - alpha) * current[i].z),
        }));

        // Step 3: HC correction — push back to preserve features
        current = smoothed.map((lm, i) => {
            const neighbors = adj.get(i);
            if (!neighbors || neighbors.size === 0) {
                return {
                    x: lm.x - bVectors[i].x,
                    y: lm.y - bVectors[i].y,
                    z: lm.z - bVectors[i].z,
                };
            }

            // Average b-vectors of neighbors
            let nbx = 0, nby = 0, nbz = 0;
            for (const n of neighbors) {
                nbx += bVectors[n].x;
                nby += bVectors[n].y;
                nbz += bVectors[n].z;
            }
            const c = neighbors.size;

            return {
                x: lm.x - (beta * bVectors[i].x + (1 - beta) * (nbx / c)),
                y: lm.y - (beta * bVectors[i].y + (1 - beta) * (nby / c)),
                z: lm.z - (beta * bVectors[i].z + (1 - beta) * (nbz / c)),
            };
        });
    }

    return current;
}

/**
 * Standard Laplacian smoothing (kept for sample/demo mesh).
 */
function smoothMesh(landmarks, indices, iterations = 2, factor = 0.3) {
    const adj = buildAdjacency(landmarks.length, indices);

    let current = landmarks;
    for (let iter = 0; iter < iterations; iter++) {
        const smoothed = current.map((lm, i) => {
            const neighbors = adj.get(i);
            if (!neighbors || neighbors.size === 0) return { ...lm };

            let sx = 0, sy = 0, sz = 0;
            for (const n of neighbors) {
                sx += current[n].x;
                sy += current[n].y;
                sz += current[n].z;
            }
            const c = neighbors.size;
            return {
                x: lm.x * (1 - factor) + (sx / c) * factor,
                y: lm.y * (1 - factor) + (sy / c) * factor,
                z: lm.z * (1 - factor) + (sz / c) * factor,
            };
        });
        current = smoothed;
    }

    return current;
}

// ═══════════════════════════════════════════════════════════════════════════
// DELAUNAY TRIANGULATION — Robust mesh from 2D landmark positions
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Load Delaunator library for 2D Delaunay triangulation.
 * This produces clean, non-overlapping triangles with consistent winding.
 */
async function loadDelaunator() {
    if (Delaunator) return true;
    try {
        const mod = await import('https://cdn.jsdelivr.net/npm/delaunator@5.0.1/+esm');
        Delaunator = mod.default;
        console.log('[Delaunator] Loaded successfully');
        return true;
    } catch (e) {
        console.warn('[Delaunator] CDN load failed:', e);
        return false;
    }
}

/**
 * Build clean triangulation from 2D landmark positions using Delaunay.
 *
 * Why Delaunay instead of MediaPipe tessellation edges?
 * - MediaPipe's FACE_LANDMARKS_TESSELATION edges require reconstructing
 *   triangles via 3-clique detection, which produces inconsistent winding
 *   (some CW, some CCW), leading to random normals and spiky displacement.
 * - Delaunay triangulation on 2D positions guarantees:
 *   1. No overlapping triangles
 *   2. Consistent CCW winding
 *   3. Well-shaped triangles (maximizes minimum angle)
 *   4. Correct normals for smooth deformation
 *
 * Boundary triangles (convex hull artifacts connecting ears/chin) are
 * filtered by edge length relative to median.
 */
function buildTrianglesDelaunay(landmarks2D) {
    if (!Delaunator) return null;

    const N = landmarks2D.length;
    const coords = new Float64Array(N * 2);
    for (let i = 0; i < N; i++) {
        coords[i * 2] = landmarks2D[i].x;
        coords[i * 2 + 1] = landmarks2D[i].y;
    }

    const d = new Delaunator(coords);
    const tris = d.triangles;

    // Compute median edge length for adaptive boundary filtering
    const edgeLens = [];
    for (let i = 0; i < tris.length; i += 3) {
        const a = tris[i], b = tris[i + 1], c = tris[i + 2];
        edgeLens.push(
            Math.hypot(coords[b * 2] - coords[a * 2], coords[b * 2 + 1] - coords[a * 2 + 1]),
            Math.hypot(coords[c * 2] - coords[b * 2], coords[c * 2 + 1] - coords[b * 2 + 1]),
            Math.hypot(coords[a * 2] - coords[c * 2], coords[a * 2 + 1] - coords[c * 2 + 1])
        );
    }
    edgeLens.sort((a, b) => a - b);
    const medianEdge = edgeLens[Math.floor(edgeLens.length / 2)];
    const maxEdge = medianEdge * 3.0;

    // Filter out long boundary triangles (convex hull artifacts)
    const filtered = [];
    for (let i = 0; i < tris.length; i += 3) {
        const a = tris[i], b = tris[i + 1], c = tris[i + 2];
        const e1 = Math.hypot(coords[b * 2] - coords[a * 2], coords[b * 2 + 1] - coords[a * 2 + 1]);
        const e2 = Math.hypot(coords[c * 2] - coords[b * 2], coords[c * 2 + 1] - coords[b * 2 + 1]);
        const e3 = Math.hypot(coords[a * 2] - coords[c * 2], coords[a * 2 + 1] - coords[c * 2 + 1]);

        if (e1 <= maxEdge && e2 <= maxEdge && e3 <= maxEdge) {
            filtered.push(a, b, c);
        }
    }

    console.log(`[Delaunay] ${tris.length / 3} raw → ${filtered.length / 3} filtered (median edge: ${medianEdge.toFixed(4)})`);
    return new Uint32Array(filtered);
}

/**
 * Ensure all triangles have outward-facing normals (toward +Z / viewer).
 * After 3D calibration, the face front is toward +Z (nose protrudes in +Z).
 * If average face normal Z is negative, flip all triangle windings.
 */
function ensureOutwardFacing(indices, landmarks) {
    let sumNz = 0;
    for (let i = 0; i < indices.length; i += 3) {
        const a = landmarks[indices[i]], b = landmarks[indices[i + 1]], c = landmarks[indices[i + 2]];
        if (!a || !b || !c) continue;
        const e1x = b.x - a.x, e1y = b.y - a.y;
        const e2x = c.x - a.x, e2y = c.y - a.y;
        sumNz += e1x * e2y - e1y * e2x;
    }

    if (sumNz < 0) {
        for (let i = 0; i < indices.length; i += 3) {
            const tmp = indices[i + 1];
            indices[i + 1] = indices[i + 2];
            indices[i + 2] = tmp;
        }
        console.log('[Mesh] Flipped triangle winding → normals now face outward');
    }
    return indices;
}

// ═══════════════════════════════════════════════════════════════════════════
// CAPTURE + MESH CONSTRUCTION
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Detect mobile device for performance-adaptive processing.
 */
function isMobileDevice() {
    return /Android|iPhone|iPad|iPod|webOS|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent)
        || (navigator.maxTouchPoints > 1 && window.innerWidth < 1024);
}

/**
 * Update the processing screen status text.
 */
function updateProcessingStatus(msg) {
    const el = document.querySelector('#screen-processing p');
    if (el) el.textContent = msg;
}

/**
 * Show an error on the processing screen with a back button.
 */
function showProcessingError(msg) {
    console.error('[Process] Error:', msg);
    const container = document.querySelector('.processing-content');
    if (container) {
        container.innerHTML = `
            <div style="color: #ff6b6b; font-size: 48px;">&#9888;</div>
            <h2>Processing Error</h2>
            <p style="color: #ccc; max-width: 300px; margin: 0 auto;">${msg}</p>
            <button class="btn-primary" style="margin-top: 20px;" id="process-error-back">Back to Start</button>
        `;
        document.getElementById('process-error-back').addEventListener('click', () => showScreen('splash'));
    }
}

/**
 * Small async yield to let the browser update the UI (spinner, status text).
 */
function yieldToUI(ms = 30) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

function captureFace() {
    if (!capturedLandmarks) {
        console.warn('[Capture] No face landmarks detected — aborting');
        return;
    }

    // ─── 1. CAPTURE HIGH-RES VIDEO FRAME AS TEXTURE ───
    const video = document.getElementById('camera-video');
    const texCanvas = document.createElement('canvas');
    texCanvas.width = video.videoWidth || 1280;
    texCanvas.height = video.videoHeight || 720;
    const texCtx = texCanvas.getContext('2d');
    texCtx.drawImage(video, 0, 0, texCanvas.width, texCanvas.height);

    capturedTexture = new THREE.CanvasTexture(texCanvas);
    capturedTexture.colorSpace = THREE.SRGBColorSpace;
    capturedTexture.minFilter = THREE.LinearMipmapLinearFilter;
    capturedTexture.magFilter = THREE.LinearFilter;
    capturedTexture.anisotropy = 4;
    capturedTexture.generateMipmaps = true;

    console.log(`[Capture] Texture: ${texCanvas.width}×${texCanvas.height}`);

    // ─── 2. MULTI-FRAME AVERAGING for stable landmarks ───
    let avgLandmarks;
    if (landmarkBuffer.length >= 3) {
        avgLandmarks = averageLandmarks(landmarkBuffer);
        console.log(`[Capture] Averaged ${landmarkBuffer.length} frames for stability`);
    } else {
        avgLandmarks = capturedLandmarks.map(lm => ({ x: lm.x, y: lm.y, z: lm.z }));
        console.log(`[Capture] Single frame (only ${landmarkBuffer.length} buffered)`);
    }

    // ─── 3. UV COORDINATES from averaged 2D positions ───
    capturedUVs = avgLandmarks.map(lm => ({
        u: lm.x,
        v: 1.0 - lm.y
    }));

    // Stop camera
    if (videoStream) { videoStream.getTracks().forEach(t => t.stop()); videoStream = null; }

    showScreen('processing');
    updateProcessingStatus('Capturing face data...');

    // ─── ASYNC PROCESSING PIPELINE ───
    // Broken into steps with UI yields to prevent browser freeze on mobile.
    const mobile = isMobileDevice();
    console.log(`[Process] Device: ${mobile ? 'MOBILE' : 'DESKTOP'}`);

    (async () => {
        try {
            // ─── Step 1: DELAUNAY TRIANGULATION from 2D positions ───
            // Build triangulation BEFORE 3D calibration (2D gives clean results)
            updateProcessingStatus('Building mesh triangulation...');
            await yieldToUI();

            if (!Delaunator) await loadDelaunator();

            if (Delaunator) {
                triangleIndices = buildTrianglesDelaunay(avgLandmarks);
                console.log(`[Process] Step 1/6: Delaunay → ${triangleIndices ? triangleIndices.length / 3 : 0} triangles`);
            }

            // Fallback to MediaPipe tessellation or spatial hashing
            if (!triangleIndices || triangleIndices.length === 0) {
                console.log('[Process] Delaunay unavailable, using fallback triangulation');
                // Try with calibrated landmarks for fallback
                const tempCal = calibrateLandmarksTo3D(avgLandmarks);
                const fallback = buildFallbackTriangulation(tempCal);
                if (fallback) triangleIndices = new Uint32Array(fallback);
            }

            // ─── Step 2: IPD-CALIBRATED 3D COORDINATES ───
            updateProcessingStatus('Calibrating 3D proportions...');
            await yieldToUI();

            baseLandmarks = calibrateLandmarksTo3D(avgLandmarks);
            console.log(`[Process] Step 2/6: Calibrated ${baseLandmarks.length} landmarks`);

            // ─── Step 3: FIX TRIANGLE WINDING for correct normals ───
            if (triangleIndices && triangleIndices.length > 0) {
                ensureOutwardFacing(triangleIndices, baseLandmarks);
                console.log(`[Process] Step 3/6: Winding verified`);
            }

            // ─── Step 4: ZONE WEIGHTS on original 468 landmarks ───
            updateProcessingStatus('Mapping anatomical zones...');
            await yieldToUI();

            zoneWeights = FaceZones.computeZoneWeights(baseLandmarks);
            console.log(`[Process] Step 4/6: Zone weights computed`);

            // ─── Step 5: SUBDIVISION + SMOOTHING ───
            if (triangleIndices && triangleIndices.length > 0) {
                updateProcessingStatus('Subdividing mesh...');
                await yieldToUI();

                // First subdivision: ~800 → ~3200 triangles
                let sub = subdivideMesh(baseLandmarks, triangleIndices, capturedUVs, zoneWeights);
                console.log(`[Process] Step 5a/6: Subdivision 1 → ${sub.landmarks.length} verts`);

                // Second subdivision only on desktop
                if (!mobile) {
                    updateProcessingStatus('Refining mesh...');
                    await yieldToUI();
                    sub = subdivideMesh(sub.landmarks, sub.indices, sub.uvs, sub.weights);
                    console.log(`[Process] Step 5b/6: Subdivision 2 → ${sub.landmarks.length} verts`);
                }

                baseLandmarks = sub.landmarks;
                triangleIndices = sub.indices;
                capturedUVs = sub.uvs;
                zoneWeights = sub.weights;

                // HC Laplacian smoothing
                updateProcessingStatus('Smoothing mesh...');
                await yieldToUI();

                const hcIter = mobile ? 2 : 3;
                baseLandmarks = smoothMeshHC(baseLandmarks, triangleIndices, hcIter, 0.5, 0.65);
                console.log(`[Process] Step 5c/6: HC smoothing (${hcIter} iterations)`);

                // Fix winding again after smoothing (shouldn't change but safety)
                ensureOutwardFacing(triangleIndices, baseLandmarks);
            }

            // ─── Step 6: NORMALS ───
            updateProcessingStatus('Finalizing 3D model...');
            await yieldToUI();

            faceNormals = computeNormals(baseLandmarks);
            console.log(`[Process] Step 6/6: Done! ${baseLandmarks.length} verts, ${triangleIndices ? triangleIndices.length / 3 : 0} tris`);

            // ─── Show viewer ───
            showScreen('viewer');
            await yieldToUI(100);

            try {
                initViewer();
                buildFaceMesh(0);
                autoCenterCamera();
                console.log('[Process] ✓ Viewer ready');
            } catch (viewerErr) {
                console.error('[Viewer] Init failed:', viewerErr);
                showScreen('processing');
                showProcessingError('3D viewer failed: ' + viewerErr.message);
            }

        } catch (err) {
            console.error('[Process] Pipeline failed:', err);
            showProcessingError('Scan processing failed: ' + (err.message || 'Unknown error'));
        }
    })();
}

function useSampleFace() {
    capturedTexture = null;
    capturedUVs = null;

    showScreen('processing');

    setTimeout(() => {
        baseLandmarks = generateSampleFaceLandmarks();
        zoneWeights = FaceZones.computeZoneWeights(baseLandmarks);

        // Build grid-based triangulation directly from the sample grid structure.
        // The sample face is a 22-column grid, so we create 2 triangles per cell.
        const GRID_COLS = 22;
        const gridRows = Math.ceil(468 / GRID_COLS);
        const gridTris = [];
        for (let row = 0; row < gridRows - 1; row++) {
            for (let col = 0; col < GRID_COLS - 1; col++) {
                const tl = row * GRID_COLS + col;
                const tr = tl + 1;
                const bl = (row + 1) * GRID_COLS + col;
                const br = bl + 1;
                if (tl < 468 && tr < 468 && bl < 468 && br < 468) {
                    gridTris.push(tl, bl, tr);   // lower-left triangle
                    gridTris.push(tr, bl, br);   // upper-right triangle
                }
            }
        }
        triangleIndices = new Uint32Array(gridTris);
        console.log(`[Sample] Grid triangulation: ${gridTris.length / 3} triangles`);

        // Single-level subdivision + smoothing for demo mesh
        if (triangleIndices && triangleIndices.length > 0) {
            let sub = subdivideMesh(baseLandmarks, triangleIndices, null, zoneWeights);
            baseLandmarks = sub.landmarks;
            triangleIndices = sub.indices;
            zoneWeights = sub.weights;

            // Moderate smoothing for clean organic surface
            baseLandmarks = smoothMesh(baseLandmarks, triangleIndices, 4, 0.35);
        }

        faceNormals = computeNormals(baseLandmarks);

        showScreen('viewer');
        requestAnimationFrame(() => {
            requestAnimationFrame(() => {
                initViewer();
                buildFaceMesh(0);
                autoCenterCamera();
            });
        });
    }, 600);
}

function generateSampleFaceLandmarks() {
    const N = 468;
    const points = [];

    // Generate face-shaped point cloud using grid distribution on an ellipsoid.
    // This produces evenly-spaced vertices that triangulate cleanly.
    const cols = 22;
    const rows = Math.ceil(N / cols); // ~22

    for (let idx = 0; idx < N; idx++) {
        const row = Math.floor(idx / cols);
        const col = idx % cols;

        // UV coordinates: map to face surface (-1..1)
        const u = (col / (cols - 1)) * 2 - 1;  // horizontal
        const v = (row / (rows - 1)) * 2 - 1;  // vertical (top to bottom)

        // Elliptical face mask — clamp points to face boundary
        const faceU = u * 0.85;
        const faceV = v;
        const faceDist = Math.sqrt(faceU * faceU + faceV * faceV);
        const clampedU = faceDist > 1.0 ? u * (1.0 / faceDist) : u;
        const clampedV = faceDist > 1.0 ? v * (1.0 / faceDist) : v;

        // Face dimensions (in model units, roughly matching calibrated size)
        const x = clampedU * 0.065;
        const y = -clampedV * 0.085;  // flip Y

        // Z: spherical face curvature + nose protrusion
        const r2 = (clampedU * 0.7) ** 2 + clampedV ** 2;
        let z = 0.035 * Math.sqrt(Math.max(0, 1.0 - r2 * 0.8));

        // Nose protrusion (centered slightly below middle)
        const noseDist = Math.sqrt(clampedU ** 2 + (clampedV + 0.15) ** 2);
        if (noseDist < 0.25) {
            const noseT = 1 - noseDist / 0.25;
            z += 0.022 * noseT * noseT;
        }

        // Eye socket depressions
        const leftEyeDist = Math.sqrt((clampedU + 0.35) ** 2 + (clampedV - 0.15) ** 2);
        const rightEyeDist = Math.sqrt((clampedU - 0.35) ** 2 + (clampedV - 0.15) ** 2);
        if (leftEyeDist < 0.15) {
            z -= 0.008 * (1 - leftEyeDist / 0.15);
        }
        if (rightEyeDist < 0.15) {
            z -= 0.008 * (1 - rightEyeDist / 0.15);
        }

        points.push({ x, y, z });
    }

    // Override key anatomical landmarks for zone system compatibility
    points[1]   = { x: 0, y: 0.015, z: 0.055 };       // nose tip
    points[6]   = { x: 0, y: -0.020, z: 0.042 };      // bridge top (nasion)
    points[4]   = { x: 0, y: 0.005, z: 0.052 };       // supratip
    points[5]   = { x: 0, y: -0.005, z: 0.048 };      // mid-dorsum
    points[2]   = { x: 0, y: 0.025, z: 0.048 };       // sub-tip
    points[164] = { x: 0, y: 0.032, z: 0.040 };       // columella base
    points[48]  = { x: -0.015, y: 0.015, z: 0.042 };  // left alar
    points[278] = { x: 0.015, y: 0.015, z: 0.042 };   // right alar
    points[60]  = { x: -0.008, y: 0.020, z: 0.045 };  // left nostril
    points[290] = { x: 0.008, y: 0.020, z: 0.045 };   // right nostril
    points[133] = { x: -0.025, y: -0.012, z: 0.022 }; // left inner eye
    points[362] = { x: 0.025, y: -0.012, z: 0.022 };  // right inner eye
    points[33]  = { x: -0.040, y: -0.012, z: 0.015 }; // left outer eye
    points[263] = { x: 0.040, y: -0.012, z: 0.015 };  // right outer eye
    points[116] = { x: -0.022, y: -0.002, z: 0.028 }; // left infraorbital
    points[345] = { x: 0.022, y: -0.002, z: 0.028 };  // right infraorbital
    points[152] = { x: 0, y: 0.075, z: 0.012 };       // chin
    points[10]  = { x: 0, y: -0.080, z: 0.025 };      // forehead
    points[168] = { x: 0, y: -0.035, z: 0.035 };      // glabella

    return points;
}

/**
 * Fallback triangulation using spatial hashing.
 */
function buildFallbackTriangulation(landmarks) {
    if (!landmarks || landmarks.length < 3) return null;

    const indices = [];
    const sorted = landmarks.map((lm, i) => ({ x: lm.x, y: lm.y, idx: i }));
    sorted.sort((a, b) => a.y - b.y || a.x - b.x);

    const cellSize = 0.008;
    const grid = new Map();
    for (const pt of sorted) {
        const key = `${Math.floor(pt.x / cellSize)},${Math.floor(pt.y / cellSize)}`;
        if (!grid.has(key)) grid.set(key, []);
        grid.get(key).push(pt);
    }

    const seen = new Set();
    for (const pt of sorted) {
        const gx = Math.floor(pt.x / cellSize);
        const gy = Math.floor(pt.y / cellSize);

        const neighbors = [];
        for (let dx = -1; dx <= 1; dx++) {
            for (let dy = -1; dy <= 1; dy++) {
                const cell = grid.get(`${gx + dx},${gy + dy}`);
                if (cell) for (const nb of cell) if (nb.idx !== pt.idx) neighbors.push(nb);
            }
        }

        neighbors.sort((a, b) =>
            ((a.x - pt.x) ** 2 + (a.y - pt.y) ** 2) - ((b.x - pt.x) ** 2 + (b.y - pt.y) ** 2)
        );

        const closest = neighbors.slice(0, 8);
        for (let i = 0; i < closest.length; i++) {
            for (let j = i + 1; j < closest.length; j++) {
                const tri = [pt.idx, closest[i].idx, closest[j].idx].sort((a, b) => a - b);
                const key = `${tri[0]},${tri[1]},${tri[2]}`;
                if (!seen.has(key)) {
                    const p0 = landmarks[tri[0]], p1 = landmarks[tri[1]], p2 = landmarks[tri[2]];
                    const e1x = p1.x - p0.x, e1y = p1.y - p0.y;
                    const e2x = p2.x - p0.x, e2y = p2.y - p0.y;
                    const area = Math.abs(e1x * e2y - e1y * e2x);
                    const maxE = Math.max(
                        Math.hypot(e1x, e1y), Math.hypot(e2x, e2y),
                        Math.hypot(p2.x - p1.x, p2.y - p1.y)
                    );
                    if (area > 1e-8 && maxE < cellSize * 3) {
                        seen.add(key);
                        indices.push(tri[0], tri[1], tri[2]);
                    }
                }
            }
        }
    }
    return indices.length > 0 ? indices : null;
}

/**
 * Compute per-vertex normals from triangles (area-weighted).
 */
function computeNormals(landmarks) {
    const normals = landmarks.map(() => ({ x: 0, y: 0, z: 0 }));

    if (triangleIndices && triangleIndices.length > 0) {
        for (let t = 0; t < triangleIndices.length; t += 3) {
            const i0 = triangleIndices[t], i1 = triangleIndices[t + 1], i2 = triangleIndices[t + 2];
            if (i0 >= landmarks.length || i1 >= landmarks.length || i2 >= landmarks.length) continue;

            const v0 = landmarks[i0], v1 = landmarks[i1], v2 = landmarks[i2];
            const e1x = v1.x - v0.x, e1y = v1.y - v0.y, e1z = v1.z - v0.z;
            const e2x = v2.x - v0.x, e2y = v2.y - v0.y, e2z = v2.z - v0.z;
            const nx = e1y * e2z - e1z * e2y;
            const ny = e1z * e2x - e1x * e2z;
            const nz = e1x * e2y - e1y * e2x;

            normals[i0].x += nx; normals[i0].y += ny; normals[i0].z += nz;
            normals[i1].x += nx; normals[i1].y += ny; normals[i1].z += nz;
            normals[i2].x += nx; normals[i2].y += ny; normals[i2].z += nz;
        }
        for (const n of normals) {
            const len = Math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
            if (len > 1e-8) { n.x /= len; n.y /= len; n.z /= len; }
            else { n.x = 0; n.y = 0; n.z = 1; }
        }
    } else {
        let cx = 0, cy = 0, cz = 0;
        for (const lm of landmarks) { cx += lm.x; cy += lm.y; cz += lm.z; }
        cx /= landmarks.length; cy /= landmarks.length; cz /= landmarks.length;
        for (let i = 0; i < landmarks.length; i++) {
            const dx = landmarks[i].x - cx, dy = landmarks[i].y - cy, dz = landmarks[i].z - cz;
            const len = Math.sqrt(dx * dx + dy * dy + dz * dz);
            normals[i] = len > 0 ? { x: dx / len, y: dy / len, z: dz / len } : { x: 0, y: 0, z: 1 };
        }
    }
    return normals;
}

// ═══════════════════════════════════════════════════════════════════════════
// THREE.JS VIEWER
// ═══════════════════════════════════════════════════════════════════════════

function initViewer() {
    const container = document.getElementById('viewer-canvas');
    while (container.firstChild) container.removeChild(container.firstChild);

    const w = container.clientWidth || window.innerWidth - 24;
    const h = container.clientHeight || Math.round(window.innerHeight * 0.45);

    scene = new THREE.Scene();
    scene.background = new THREE.Color(0x1a1a2e);

    threeCamera = new THREE.PerspectiveCamera(35, w / h, 0.001, 10);
    threeCamera.position.set(0, 0, 0.35);

    renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false });
    renderer.setSize(w, h);
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.0;
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    container.appendChild(renderer.domElement);

    controls = new OrbitControls(threeCamera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.08;
    controls.target.set(0, 0, 0);
    controls.minDistance = 0.05;
    controls.maxDistance = 2;
    controls.enablePan = true;

    // ── STUDIO-QUALITY LIGHTING ──
    // Key light (front, slightly elevated and offset)
    const keyLight = new THREE.DirectionalLight(0xfff5ee, 2.0);
    keyLight.position.set(0.3, 0.4, 1);
    scene.add(keyLight);

    // Fill light (softer, from opposite side)
    const fillLight = new THREE.DirectionalLight(0xe8e0f0, 1.0);
    fillLight.position.set(-0.5, 0.2, 0.8);
    scene.add(fillLight);

    // Rim light (from behind, for edge definition)
    const rimLight = new THREE.DirectionalLight(0xffffff, 0.6);
    rimLight.position.set(0, 0.3, -0.8);
    scene.add(rimLight);

    // Top light (simulates overhead/ceiling)
    const topLight = new THREE.DirectionalLight(0xffffff, 0.4);
    topLight.position.set(0, 1, 0.3);
    scene.add(topLight);

    // Bottom bounce (warm uplight for chin/neck area)
    const bounceLight = new THREE.DirectionalLight(0xffe8d0, 0.3);
    bounceLight.position.set(0, -0.5, 0.5);
    scene.add(bounceLight);

    // Ambient + hemisphere for natural falloff
    scene.add(new THREE.AmbientLight(0xffffff, 0.5));
    scene.add(new THREE.HemisphereLight(0xffeedd, 0x334466, 0.4));

    const resizeViewer = () => {
        const rw = container.clientWidth, rh = container.clientHeight;
        if (rw > 0 && rh > 0) {
            threeCamera.aspect = rw / rh;
            threeCamera.updateProjectionMatrix();
            renderer.setSize(rw, rh);
        }
    };
    window.addEventListener('resize', resizeViewer);
    if (typeof ResizeObserver !== 'undefined') {
        new ResizeObserver(resizeViewer).observe(container);
    }

    (function animate() {
        requestAnimationFrame(animate);
        controls.update();
        renderer.render(scene, threeCamera);
    })();
}

function autoCenterCamera() {
    if (!baseLandmarks || !threeCamera || !controls) return;

    let minX = Infinity, maxX = -Infinity;
    let minY = Infinity, maxY = -Infinity;
    let minZ = Infinity, maxZ = -Infinity;

    for (const lm of baseLandmarks) {
        if (lm.x < minX) minX = lm.x; if (lm.x > maxX) maxX = lm.x;
        if (lm.y < minY) minY = lm.y; if (lm.y > maxY) maxY = lm.y;
        if (lm.z < minZ) minZ = lm.z; if (lm.z > maxZ) maxZ = lm.z;
    }

    const cx = (minX + maxX) / 2, cy = (minY + maxY) / 2, cz = (minZ + maxZ) / 2;
    const maxSize = Math.max(maxX - minX, maxY - minY);
    const dist = (maxSize / 2) / Math.tan(threeCamera.fov * Math.PI / 360) * 1.4;

    threeCamera.position.set(cx, cy, cz + Math.max(dist, 0.15));
    controls.target.set(cx, cy, cz);
    controls.update();
}

/**
 * Build or update the 3D face mesh with healing deformation + texture.
 *
 * Key improvements over previous version:
 * - Displacement is CAPPED relative to face scale (prevents vertex collapse)
 * - SmoothStep weight interpolation (no hard zone boundaries)
 * - MeshPhysicalMaterial with skin-like subsurface scattering approximation
 */
function buildFaceMesh(day) {
    if (!baseLandmarks || !zoneWeights) return;

    const state = healingModel.evaluate(day);
    const hasTexture = capturedTexture && capturedUVs;

    // Remove previous
    if (faceMesh) {
        scene.remove(faceMesh);
        faceMesh.geometry.dispose();
        faceMesh.material.dispose();
        faceMesh = null;
    }
    const oldPts = scene.getObjectByName('pointCloud');
    if (oldPts) { scene.remove(oldPts); oldPts.geometry.dispose(); }

    const N = baseLandmarks.length;
    const positions = new Float32Array(N * 3);
    const colors = new Float32Array(N * 3);
    const uvs = hasTexture ? new Float32Array(N * 2) : null;

    // ── DISPLACEMENT with safety cap ──
    const rawDisplacementM = state.nasalVolumeDelta / 1000;
    const maxSafeDisplacement = faceScale * 0.05;
    const displacementM = Math.min(rawDisplacementM, maxSafeDisplacement);

    const skinR = 0.85, skinG = 0.72, skinB = 0.62;

    // ── Compute face centroid for smooth displacement directions ──
    // Blending vertex normals with radial outward direction prevents
    // spiky artifacts from inconsistent/noisy per-vertex normals.
    let fcx = 0, fcy = 0, fcz = 0, validCount = 0;
    for (const lm of baseLandmarks) {
        if (!lm) continue;
        fcx += lm.x; fcy += lm.y; fcz += lm.z;
        validCount++;
    }
    if (validCount > 0) { fcx /= validCount; fcy /= validCount; fcz /= validCount; }

    for (let i = 0; i < N; i++) {
        const lm = baseLandmarks[i];
        if (!lm) continue;
        const n = (faceNormals && faceNormals[i]) || { x: 0, y: 0, z: 1 };
        const zw = (zoneWeights && zoneWeights[i]) || DEFAULT_WEIGHT;

        // ── SMOOTH DISPLACEMENT DIRECTION ──
        // Blend vertex normal (geometry-derived) with radial outward (centroid-derived)
        // This produces organic, diffuse swelling instead of spiky per-vertex displacement
        const dx = lm.x - fcx, dy = lm.y - fcy, dz = lm.z - fcz;
        const dlen = Math.sqrt(dx * dx + dy * dy + dz * dz);
        const outX = dlen > 1e-8 ? dx / dlen : 0;
        const outY = dlen > 1e-8 ? dy / dlen : 0;
        const outZ = dlen > 1e-8 ? dz / dlen : 1;

        // 60% vertex normal + 40% outward direction
        let dirX = n.x * 0.6 + outX * 0.4;
        let dirY = n.y * 0.6 + outY * 0.4;
        let dirZ = n.z * 0.6 + outZ * 0.4;
        const dirLen = Math.sqrt(dirX * dirX + dirY * dirY + dirZ * dirZ);
        if (dirLen > 1e-8) { dirX /= dirLen; dirY /= dirLen; dirZ /= dirLen; }

        // ── SWELLING DEFORMATION ──
        const rawWeight = FaceZones.getSwellingWeight(zw);
        const swellW = rawWeight * rawWeight * (3 - 2 * rawWeight);
        positions[i * 3]     = lm.x + dirX * displacementM * swellW;
        positions[i * 3 + 1] = lm.y + dirY * displacementM * swellW;
        positions[i * 3 + 2] = lm.z + dirZ * displacementM * swellW;

        // UV
        if (uvs && capturedUVs[i]) {
            uvs[i * 2]     = capturedUVs[i].u;
            uvs[i * 2 + 1] = capturedUVs[i].v;
        }

        // Vertex colors
        let r, g, b;

        if (showZones) {
            const zColor = Array.isArray(zw.color) ? zw.color : [0.15, 0.15, 0.15];
            const [zr, zg, zb] = zColor;
            const mix = Math.max(0.2, zw.weight || 0);
            r = skinR * (1 - mix) + zr * mix;
            g = skinG * (1 - mix) + zg * mix;
            b = skinB * (1 - mix) + zb * mix;
        } else if (hasTexture) {
            // White = show texture as-is. Tinting = healing overlay.
            r = 1.0; g = 1.0; b = 1.0;

            // Bruise tint
            const bruiseW = FaceZones.getBruisingWeight(zw);
            const bruiseI = state.bruisingLevel * bruiseW;
            if (bruiseI > 0.01) {
                const [br, bg, bb] = state.bruiseColor;
                const s = bruiseI * 0.6;
                r = r * (1 - s) + br * s;
                g = g * (1 - s) + bg * s;
                b = b * (1 - s) + bb * s;
                const dk = 1.0 - bruiseI * 0.2;
                r *= dk; g *= dk; b *= dk;
            }

            // Swelling redness
            const sr = state.swellingLevel * swellW * 0.06;
            if (sr > 0.01) { r = Math.min(1, r + sr * 0.4); g -= sr * 0.1; b -= sr * 0.08; }
        } else {
            // Demo mode: skin colors
            r = skinR; g = skinG; b = skinB;

            const bruiseW = FaceZones.getBruisingWeight(zw);
            const bruiseI = state.bruisingLevel * bruiseW;
            if (bruiseI > 0.01) {
                const [br, bg, bb] = state.bruiseColor;
                r = skinR * (1 - bruiseI * 0.7) + br * bruiseI * 0.7;
                g = skinG * (1 - bruiseI * 0.7) + bg * bruiseI * 0.7;
                b = skinB * (1 - bruiseI * 0.7) + bb * bruiseI * 0.7;
                r *= (1 - bruiseI * 0.15); g *= (1 - bruiseI * 0.15); b *= (1 - bruiseI * 0.15);
            }
            const sr = state.swellingLevel * swellW * 0.12;
            r = Math.min(1, r + sr); g = Math.max(0, g - sr * 0.3);
        }

        colors[i * 3] = Math.max(0, Math.min(1, r));
        colors[i * 3 + 1] = Math.max(0, Math.min(1, g));
        colors[i * 3 + 2] = Math.max(0, Math.min(1, b));
    }

    // Build geometry
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    geo.setAttribute('color', new THREE.BufferAttribute(colors, 3));
    if (uvs) geo.setAttribute('uv', new THREE.BufferAttribute(uvs, 2));

    if (triangleIndices && triangleIndices.length > 0) {
        geo.setIndex(new THREE.BufferAttribute(triangleIndices, 1));
        geo.computeVertexNormals();

        // ── SKIN-LIKE MATERIAL (MeshPhysicalMaterial) ──
        // Provides clearcoat (skin sheen) and sheen (subsurface scattering approx)
        const mat = new THREE.MeshPhysicalMaterial({
            map: (hasTexture && !showZones) ? capturedTexture : null,
            vertexColors: true,
            roughness: 0.55,
            metalness: 0.0,
            clearcoat: 0.04,            // Subtle skin sheen
            clearcoatRoughness: 0.85,
            sheen: 0.3,                 // Subsurface scattering approximation
            sheenRoughness: 0.8,
            sheenColor: new THREE.Color(0.95, 0.65, 0.55),  // Warm skin undertone
            side: THREE.DoubleSide,
            flatShading: false,
        });

        faceMesh = new THREE.Mesh(geo, mat);
        faceMesh.name = 'faceMesh';
        scene.add(faceMesh);
    }

    // Update UI
    updateViewerUI(state);
}

// ═══════════════════════════════════════════════════════════════════════════
// UI MANAGEMENT
// ═══════════════════════════════════════════════════════════════════════════

function showScreen(screen) {
    currentScreen = screen;
    document.querySelectorAll('.screen').forEach(el => el.classList.remove('active'));
    document.getElementById(`screen-${screen}`).classList.add('active');

    if (screen === 'scan') {
        stableFrames = 0;
        landmarkBuffer = [];
        document.getElementById('capture-btn').style.display = '';
        const fb = document.getElementById('camera-fallback-btn');
        if (fb) fb.remove();
        startCamera();
    }
}

function updateViewerUI(state) {
    const dayLabel = document.getElementById('day-label');
    const swellPct = document.getElementById('swell-pct');
    const bruisePct = document.getElementById('bruise-pct');
    const bruiseDot = document.getElementById('bruise-dot');
    const bruiseRow = document.getElementById('bruise-row');

    const d = state.day;
    if (d === 0) dayLabel.textContent = 'Surgery Day';
    else if (d === 1) dayLabel.textContent = 'Day 1';
    else if (d < 30) dayLabel.textContent = `Day ${Math.round(d)}`;
    else if (d < 365) dayLabel.textContent = `${Math.round(d / 30)} month${Math.round(d / 30) > 1 ? 's' : ''}`;
    else dayLabel.textContent = '12 months';

    swellPct.textContent = `${Math.round(state.swellingLevel * 100)}%`;
    swellPct.className = 'stat-value ' + (
        state.swellingLevel > 0.6 ? 'high' : state.swellingLevel > 0.3 ? 'med' :
        state.swellingLevel > 0.1 ? 'low' : 'min'
    );

    if (state.bruisingLevel > 0.01) {
        bruiseRow.style.display = 'flex';
        bruisePct.textContent = `${Math.round(state.bruisingLevel * 100)}%`;
        const [br, bg, bb] = state.bruiseColor;
        bruiseDot.style.backgroundColor = `rgb(${Math.round(br * 255)},${Math.round(bg * 255)},${Math.round(bb * 255)})`;
    } else {
        bruiseRow.style.display = 'none';
    }
}

function setDay(day) {
    currentDay = day;
    document.getElementById('timeline-slider').value = day;
    buildFaceMesh(day);
}

function updateProfile() {
    healingModel = new HealingModelJS.HealingModel({
        skinThickness: document.getElementById('opt-skin').value,
        initialIntensity: document.getElementById('opt-intensity').value,
        bruisingPresent: document.getElementById('opt-bruising').checked,
    });
    buildFaceMesh(currentDay);
}

// ═══════════════════════════════════════════════════════════════════════════
// ZONE LEGEND
// ═══════════════════════════════════════════════════════════════════════════

function buildZoneLegend() {
    const container = document.getElementById('zone-legend');
    container.innerHTML = '';
    for (const [name, zone] of Object.entries(FaceZones.ZONES)) {
        const item = document.createElement('div');
        item.className = 'legend-item';
        const dot = document.createElement('span');
        dot.className = 'legend-dot';
        const [r, g, b] = zone.color;
        dot.style.backgroundColor = `rgb(${Math.round(r * 255)},${Math.round(g * 255)},${Math.round(b * 255)})`;
        const label = document.createElement('span');
        label.className = 'legend-label';
        label.textContent = `${zone.label} (${Math.round(zone.weight * 100)}%)`;
        item.appendChild(dot);
        item.appendChild(label);
        container.appendChild(item);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// EVENT BINDINGS
// ═══════════════════════════════════════════════════════════════════════════

function init() {
    document.getElementById('start-btn').addEventListener('click', () => showScreen('scan'));
    document.getElementById('demo-btn').addEventListener('click', useSampleFace);
    document.getElementById('capture-btn').addEventListener('click', captureFace);
    document.getElementById('scan-back-btn').addEventListener('click', () => showScreen('splash'));

    document.getElementById('viewer-back-btn').addEventListener('click', () => {
        showScreen('splash');
        if (faceMesh) { scene.remove(faceMesh); }
        baseLandmarks = null;
        if (capturedTexture) { capturedTexture.dispose(); capturedTexture = null; }
        capturedUVs = null;
        landmarkBuffer = [];
    });

    document.getElementById('timeline-slider').addEventListener('input', (e) => setDay(parseFloat(e.target.value)));

    document.querySelectorAll('.preset-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            setDay(parseFloat(btn.dataset.day));
            document.querySelectorAll('.preset-btn').forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
        });
    });

    document.getElementById('opt-skin').addEventListener('change', updateProfile);
    document.getElementById('opt-intensity').addEventListener('change', updateProfile);
    document.getElementById('opt-bruising').addEventListener('change', updateProfile);

    document.getElementById('zone-toggle').addEventListener('change', (e) => {
        showZones = e.target.checked;
        buildFaceMesh(currentDay);
        document.getElementById('zone-legend').style.display = showZones ? 'block' : 'none';
    });

    document.getElementById('disclaimer-ok').addEventListener('click', () => {
        document.getElementById('disclaimer-modal').style.display = 'none';
    });

    buildZoneLegend();
    initMediaPipe();
}

document.addEventListener('DOMContentLoaded', init);
