/**
 * app.js — Main application: MediaPipe face capture + Three.js 3D viewer + timeline.
 *
 * KEY FEATURES:
 * - Captures camera frame as texture and UV-maps it onto the 3D face mesh
 * - Subdivides the 468-point MediaPipe mesh for smooth surface (~2000 vertices)
 * - Applies Laplacian smoothing for natural-looking geometry
 * - Healing simulation (swelling deformation + bruise color overlay) on top of texture
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

// Three.js
let scene, threeCamera, renderer, controls;
let faceMesh = null;
let baseLandmarks = null;
let faceNormals = null;
let triangleIndices = null;

// Face texture from camera
let capturedTexture = null;
let capturedUVs = null;

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
        videoStream = await navigator.mediaDevices.getUserMedia({
            video: { facingMode: 'user', width: { ideal: 640 }, height: { ideal: 480 } }
        });
        video.srcObject = videoStream;
        await video.play();

        canvas.width = video.videoWidth;
        canvas.height = video.videoHeight;
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
        } else {
            updateTrackingUI(false);
            capturedLandmarks = null;
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
// MESH SUBDIVISION + SMOOTHING
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Subdivide a triangle mesh by splitting each triangle into 4.
 * Creates midpoint vertices on each edge with interpolated UVs and weights.
 * Result: ~4x triangles, ~2x vertices → much smoother surface.
 */
function subdivideMesh(landmarks, indices, uvData, weights) {
    const edgeMap = new Map();
    const newLandmarks = landmarks.map(lm => ({ ...lm }));
    const newUVs = uvData ? uvData.map(uv => ({ ...uv })) : null;
    const newWeights = weights.map(w => ({ ...w, color: [...w.color] }));
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

        // Interpolate zone weight
        const w0 = weights[i0], w1 = weights[i1];
        newWeights.push({
            zone: w0.weight >= w1.weight ? w0.zone : w1.zone,
            weight: (w0.weight + w1.weight) / 2,
            color: [
                (w0.color[0] + w1.color[0]) / 2,
                (w0.color[1] + w1.color[1]) / 2,
                (w0.color[2] + w1.color[2]) / 2,
            ],
            isBruiseZone: w0.isBruiseZone || w1.isBruiseZone,
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
 * Laplacian smoothing: moves each vertex toward the average of its neighbors.
 * Produces smoother, more natural-looking surfaces without changing topology.
 */
function smoothMesh(landmarks, indices, iterations = 2, factor = 0.3) {
    // Build adjacency
    const adj = new Map();
    for (let t = 0; t < indices.length; t += 3) {
        const verts = [indices[t], indices[t + 1], indices[t + 2]];
        for (let i = 0; i < 3; i++) {
            for (let j = i + 1; j < 3; j++) {
                if (!adj.has(verts[i])) adj.set(verts[i], new Set());
                if (!adj.has(verts[j])) adj.set(verts[j], new Set());
                adj.get(verts[i]).add(verts[j]);
                adj.get(verts[j]).add(verts[i]);
            }
        }
    }

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
// CAPTURE + MESH CONSTRUCTION
// ═══════════════════════════════════════════════════════════════════════════

function captureFace() {
    if (!capturedLandmarks) return;

    // ─── Capture video frame as texture BEFORE stopping camera ───
    const video = document.getElementById('camera-video');
    const texCanvas = document.createElement('canvas');
    texCanvas.width = video.videoWidth || 640;
    texCanvas.height = video.videoHeight || 480;
    const texCtx = texCanvas.getContext('2d');

    // Draw raw video frame (no mirror — UV mapping handles coordinates directly)
    texCtx.drawImage(video, 0, 0, texCanvas.width, texCanvas.height);

    capturedTexture = new THREE.CanvasTexture(texCanvas);
    capturedTexture.colorSpace = THREE.SRGBColorSpace;
    capturedTexture.minFilter = THREE.LinearFilter;
    capturedTexture.magFilter = THREE.LinearFilter;
    capturedTexture.generateMipmaps = false;

    // UV coordinates = original 2D landmark positions (direct mapping to raw frame)
    capturedUVs = capturedLandmarks.map(lm => ({
        u: lm.x,           // direct x mapping to texture
        v: 1.0 - lm.y      // flip y (Three.js v goes bottom-to-top)
    }));

    console.log(`[Capture] Frame: ${texCanvas.width}x${texCanvas.height}, UVs: ${capturedUVs.length}`);

    // Stop camera
    if (videoStream) { videoStream.getTracks().forEach(t => t.stop()); videoStream = null; }

    showScreen('processing');

    setTimeout(() => {
        // Convert landmarks to 3D coordinates
        baseLandmarks = capturedLandmarks.map(lm => ({
            x: (lm.x - 0.5) * 0.2,
            y: -(lm.y - 0.5) * 0.2,
            z: -lm.z * 0.3        // increased depth scale for better 3D relief
        }));

        // Compute zone weights on original 468 landmarks
        zoneWeights = FaceZones.computeZoneWeights(baseLandmarks);

        // Ensure we have triangle indices (tessellation or fallback)
        if (!triangleIndices || triangleIndices.length === 0) {
            const fallback = buildFallbackTriangulation(baseLandmarks);
            if (fallback) triangleIndices = new Uint32Array(fallback);
        }

        // ─── SUBDIVIDE for smoother mesh ───
        if (triangleIndices && triangleIndices.length > 0) {
            const sub = subdivideMesh(baseLandmarks, triangleIndices, capturedUVs, zoneWeights);
            baseLandmarks = sub.landmarks;
            triangleIndices = sub.indices;
            capturedUVs = sub.uvs;
            zoneWeights = sub.weights;

            // Laplacian smoothing for natural surface
            baseLandmarks = smoothMesh(baseLandmarks, triangleIndices, 2, 0.25);
        }

        // Compute normals on subdivided + smoothed mesh
        faceNormals = computeNormals(baseLandmarks);

        // Show viewer, then init 3D
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

function useSampleFace() {
    capturedTexture = null;
    capturedUVs = null;

    showScreen('processing');

    setTimeout(() => {
        baseLandmarks = generateSampleFaceLandmarks();
        zoneWeights = FaceZones.computeZoneWeights(baseLandmarks);

        // Ensure triangles
        if (!triangleIndices || triangleIndices.length === 0) {
            const fallback = buildFallbackTriangulation(baseLandmarks);
            if (fallback) triangleIndices = new Uint32Array(fallback);
        }

        // Subdivide
        if (triangleIndices && triangleIndices.length > 0) {
            const sub = subdivideMesh(baseLandmarks, triangleIndices, null, zoneWeights);
            baseLandmarks = sub.landmarks;
            triangleIndices = sub.indices;
            zoneWeights = sub.weights;
            baseLandmarks = smoothMesh(baseLandmarks, triangleIndices, 2, 0.25);
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
    const points = [];
    for (let i = 0; i < 468; i++) {
        const t = i / 467;
        const angle = t * Math.PI * 15.7;
        const r = Math.sqrt(t) * 0.08;

        let x = r * Math.cos(angle);
        let y = r * Math.sin(angle) * 1.3 - 0.01;
        let z = 0.02 * Math.cos(t * Math.PI);

        if (FaceZones.ALL_NOSE_LANDMARKS.has(i)) {
            z += 0.02;
            if (i === 1 || i === 2 || i === 4) { z += 0.015; y -= 0.005; }
        }

        points.push({ x, y, z });
    }

    points[1]   = { x: 0, y: -0.015, z: 0.05 };
    points[6]   = { x: 0, y: 0.025, z: 0.035 };
    points[4]   = { x: 0, y: -0.005, z: 0.045 };
    points[5]   = { x: 0, y: 0.005, z: 0.04 };
    points[2]   = { x: 0, y: -0.025, z: 0.04 };
    points[164] = { x: 0, y: -0.03, z: 0.035 };
    points[48]  = { x: -0.015, y: -0.015, z: 0.035 };
    points[278] = { x: 0.015, y: -0.015, z: 0.035 };
    points[60]  = { x: -0.008, y: -0.02, z: 0.038 };
    points[290] = { x: 0.008, y: -0.02, z: 0.038 };
    points[133] = { x: -0.025, y: 0.015, z: 0.02 };
    points[362] = { x: 0.025, y: 0.015, z: 0.02 };
    points[116] = { x: -0.022, y: 0.005, z: 0.025 };
    points[345] = { x: 0.022, y: 0.005, z: 0.025 };
    points[152] = { x: 0, y: -0.07, z: 0.01 };
    points[168] = { x: 0, y: 0.04, z: 0.03 };

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
 * Compute per-vertex normals from triangles.
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
    scene.background = new THREE.Color(0x16162a);

    threeCamera = new THREE.PerspectiveCamera(40, w / h, 0.001, 10);
    threeCamera.position.set(0, 0, 0.35);

    renderer = new THREE.WebGLRenderer({ antialias: true });
    renderer.setSize(w, h);
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.1;
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    container.appendChild(renderer.domElement);

    controls = new OrbitControls(threeCamera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.08;
    controls.target.set(0, 0, 0);
    controls.minDistance = 0.05;
    controls.maxDistance = 2;
    controls.enablePan = true;

    // Lighting — even, soft illumination to show the face texture naturally
    const front = new THREE.DirectionalLight(0xffffff, 1.8);
    front.position.set(0, 0.2, 1);
    scene.add(front);

    const left = new THREE.DirectionalLight(0xffffff, 1.0);
    left.position.set(-0.6, 0.3, 0.7);
    scene.add(left);

    const right = new THREE.DirectionalLight(0xffffff, 1.0);
    right.position.set(0.6, 0.3, 0.7);
    scene.add(right);

    const top = new THREE.DirectionalLight(0xffffff, 0.5);
    top.position.set(0, 1, 0.2);
    scene.add(top);

    scene.add(new THREE.AmbientLight(0xffffff, 0.8));
    scene.add(new THREE.HemisphereLight(0xffffff, 0x444466, 0.4));

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

    const displacementM = state.nasalVolumeDelta / 1000;
    const skinR = 0.85, skinG = 0.72, skinB = 0.62;

    for (let i = 0; i < N; i++) {
        const lm = baseLandmarks[i];
        const n = faceNormals[i];
        const zw = zoneWeights[i];

        // Swelling deformation
        const swellW = FaceZones.getSwellingWeight(zw);
        positions[i * 3]     = lm.x + n.x * displacementM * swellW;
        positions[i * 3 + 1] = lm.y + n.y * displacementM * swellW;
        positions[i * 3 + 2] = lm.z + n.z * displacementM * swellW;

        // UV
        if (uvs && capturedUVs[i]) {
            uvs[i * 2]     = capturedUVs[i].u;
            uvs[i * 2 + 1] = capturedUVs[i].v;
        }

        // Vertex colors
        let r, g, b;

        if (showZones) {
            const [zr, zg, zb] = zw.color || [0.15, 0.15, 0.15];
            const mix = Math.max(0.2, zw.weight);
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

        const mat = new THREE.MeshStandardMaterial({
            map: (hasTexture && !showZones) ? capturedTexture : null,
            vertexColors: true,
            roughness: 0.6,
            metalness: 0.0,
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
