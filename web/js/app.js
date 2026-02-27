/**
 * app.js — Main application: MediaPipe face capture + Three.js 3D viewer + timeline.
 *
 * ES Module. Imports Three.js and MediaPipe from CDN.
 * Uses FaceZones and HealingModelJS from global scope (loaded via script tags).
 *
 * KEY FEATURE: Captures camera frame as texture and maps it onto the 3D face mesh
 * so the user sees their actual face in 3D, with healing simulation overlaid.
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
let baseLandmarks = null;  // original positions for deformation
let faceNormals = null;
let triangleIndices = null;

// Face texture from camera
let capturedTexture = null;   // THREE.CanvasTexture from camera frame
let capturedUVs = null;       // Original 2D landmark positions for UV mapping

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
            console.log(`[MediaPipe] Tessellation found: ${tessData.length} edges`);
        } else {
            console.warn('[MediaPipe] No tessellation data found — will use fallback triangulation');
        }

        statusEl.textContent = 'Ready!';
        document.getElementById('start-btn').disabled = false;
        console.log('[MediaPipe] FaceLandmarker ready. Triangles:', triangleIndices ? triangleIndices.length / 3 : 'fallback');
    } catch (err) {
        console.error('[MediaPipe] Init failed:', err);
        statusEl.textContent = 'Failed to load model. Check internet connection.';
    }
}

/**
 * Convert FACE_LANDMARKS_TESSELATION edges into triangle indices.
 * Algorithm: for each edge (a,b), find common neighbors c to form triangles.
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
        const neighborsA = adj.get(a);
        const neighborsB = adj.get(b);
        if (!neighborsA || !neighborsB) continue;

        for (const c of neighborsA) {
            if (neighborsB.has(c)) {
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
    console.log(`[Mesh] Computed ${tris.length / 3} triangles from ${edges.length} edges`);
}

// ═══════════════════════════════════════════════════════════════════════════
// CAMERA + FACE TRACKING
// ═══════════════════════════════════════════════════════════════════════════

async function startCamera() {
    const video = document.getElementById('camera-video');
    const canvas = document.getElementById('camera-overlay');
    const ctx = canvas.getContext('2d');
    const instructionEl = document.getElementById('scan-instruction');

    // Check secure context (camera requires HTTPS or localhost)
    if (!window.isSecureContext || !navigator.mediaDevices) {
        console.warn('[Camera] Not a secure context — camera unavailable');
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

        // Start detection loop
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

/**
 * Show camera error with a fallback button to use demo mode.
 */
function showCameraError(instructionEl, message) {
    const bottomEl = document.querySelector('.scan-bottom');
    instructionEl.textContent = message;

    // Hide the capture button
    document.getElementById('capture-btn').style.display = 'none';

    // Add fallback button if not already present
    if (!document.getElementById('camera-fallback-btn')) {
        const fallbackBtn = document.createElement('button');
        fallbackBtn.id = 'camera-fallback-btn';
        fallbackBtn.className = 'btn-primary';
        fallbackBtn.textContent = 'Use Demo Mode Instead';
        fallbackBtn.style.maxWidth = '260px';
        fallbackBtn.addEventListener('click', () => {
            // Cleanup
            if (videoStream) {
                videoStream.getTracks().forEach(t => t.stop());
                videoStream = null;
            }
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
            // Store for capture
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

    // Draw nose tip crosshair
    const tip = landmarks[1];
    const tx = tip.x * w;
    const ty = tip.y * h;
    ctx.strokeStyle = '#ff3333';
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(tx - 8, ty); ctx.lineTo(tx + 8, ty);
    ctx.moveTo(tx, ty - 8); ctx.lineTo(tx, ty + 8);
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
// CAPTURE + MESH CONSTRUCTION
// ═══════════════════════════════════════════════════════════════════════════

function captureFace() {
    if (!capturedLandmarks) return;

    // ─── Capture video frame as texture BEFORE stopping the camera ───
    const video = document.getElementById('camera-video');
    const texCanvas = document.createElement('canvas');
    texCanvas.width = video.videoWidth || 640;
    texCanvas.height = video.videoHeight || 480;
    const texCtx = texCanvas.getContext('2d');

    // Draw the video frame (mirrored to match what user sees)
    texCtx.translate(texCanvas.width, 0);
    texCtx.scale(-1, 1);
    texCtx.drawImage(video, 0, 0, texCanvas.width, texCanvas.height);

    // Create Three.js texture from captured frame
    capturedTexture = new THREE.CanvasTexture(texCanvas);
    capturedTexture.colorSpace = THREE.SRGBColorSpace;
    capturedTexture.minFilter = THREE.LinearFilter;
    capturedTexture.magFilter = THREE.LinearFilter;
    capturedTexture.generateMipmaps = false;

    // Store original 2D positions as UV coordinates
    // Since we mirrored the texture, u = 1 - lm.x to match
    capturedUVs = capturedLandmarks.map(lm => ({
        u: 1.0 - lm.x,   // mirror x to match mirrored texture
        v: 1.0 - lm.y     // flip y (Three.js v goes bottom-to-top)
    }));

    console.log(`[Capture] Video frame captured: ${texCanvas.width}x${texCanvas.height}, UVs computed for ${capturedUVs.length} landmarks`);

    // Stop camera
    if (videoStream) {
        videoStream.getTracks().forEach(t => t.stop());
        videoStream = null;
    }

    showScreen('processing');

    // Process asynchronously
    setTimeout(() => {
        baseLandmarks = capturedLandmarks.map(lm => ({
            x: (lm.x - 0.5) * 0.2,    // center and scale to ~20cm
            y: -(lm.y - 0.5) * 0.2,    // flip Y (MediaPipe Y is top-down)
            z: -lm.z * 0.2              // Z: depth
        }));

        // Compute zone weights
        zoneWeights = FaceZones.computeZoneWeights(baseLandmarks);

        // Compute normals
        faceNormals = computeNormals(baseLandmarks);

        // Show viewer FIRST so the container has layout dimensions
        showScreen('viewer');

        // Wait for the browser to compute layout, then init 3D
        requestAnimationFrame(() => {
            requestAnimationFrame(() => {
                initViewer();
                buildFaceMesh(0);
                autoCenterCamera();
            });
        });
    }, 500);
}

/**
 * Use sample/generated face for demo mode (no camera needed).
 */
function useSampleFace() {
    // No texture in demo mode
    capturedTexture = null;
    capturedUVs = null;

    showScreen('processing');

    setTimeout(() => {
        baseLandmarks = generateSampleFaceLandmarks();
        zoneWeights = FaceZones.computeZoneWeights(baseLandmarks);
        faceNormals = computeNormals(baseLandmarks);

        // Show viewer FIRST so the container has layout dimensions
        showScreen('viewer');

        requestAnimationFrame(() => {
            requestAnimationFrame(() => {
                initViewer();
                buildFaceMesh(0);
                autoCenterCamera();
            });
        });
    }, 500);
}

/**
 * Generate 468 synthetic face landmarks (no real data).
 */
function generateSampleFaceLandmarks() {
    const points = [];
    for (let i = 0; i < 468; i++) {
        // Distribute points in a face-like ellipsoid
        const t = i / 467;
        const angle = t * Math.PI * 15.7; // golden angle spiral
        const r = Math.sqrt(t) * 0.08;

        let x = r * Math.cos(angle);
        let y = r * Math.sin(angle) * 1.3 - 0.01; // slightly taller
        let z = 0.02 * Math.cos(t * Math.PI); // slight depth

        // Add nose protrusion for landmarks in nose zone
        if (FaceZones.ALL_NOSE_LANDMARKS.has(i)) {
            z += 0.02;
            // Tip landmarks protrude more
            if (i === 1 || i === 2 || i === 4) {
                z += 0.015;
                y -= 0.005;
            }
        }

        points.push({ x, y, z });
    }

    // Override key landmarks for anatomical accuracy
    points[1]   = { x: 0, y: -0.015, z: 0.05 };       // nose tip
    points[6]   = { x: 0, y: 0.025, z: 0.035 };        // nasion
    points[4]   = { x: 0, y: -0.005, z: 0.045 };       // supratip
    points[5]   = { x: 0, y: 0.005, z: 0.04 };         // mid-dorsum
    points[2]   = { x: 0, y: -0.025, z: 0.04 };        // columella
    points[164] = { x: 0, y: -0.03, z: 0.035 };        // subnasale
    points[48]  = { x: -0.015, y: -0.015, z: 0.035 };  // left alar
    points[278] = { x: 0.015, y: -0.015, z: 0.035 };   // right alar
    points[60]  = { x: -0.008, y: -0.02, z: 0.038 };   // left nostril
    points[290] = { x: 0.008, y: -0.02, z: 0.038 };    // right nostril
    points[133] = { x: -0.025, y: 0.015, z: 0.02 };    // left eye inner
    points[362] = { x: 0.025, y: 0.015, z: 0.02 };     // right eye inner
    points[116] = { x: -0.022, y: 0.005, z: 0.025 };   // left infraorbital
    points[345] = { x: 0.022, y: 0.005, z: 0.025 };    // right infraorbital
    points[152] = { x: 0, y: -0.07, z: 0.01 };         // chin
    points[168] = { x: 0, y: 0.04, z: 0.03 };          // glabella

    return points;
}

/**
 * Fallback triangulation using simple 2D Delaunay-like approach.
 * Projects landmarks to 2D (x,y) and creates triangles via a grid-based method.
 */
function buildFallbackTriangulation(landmarks) {
    if (!landmarks || landmarks.length < 3) return null;

    const indices = [];
    const sorted = landmarks.map((lm, i) => ({ x: lm.x, y: lm.y, z: lm.z, idx: i }));
    sorted.sort((a, b) => a.y - b.y || a.x - b.x);

    const cellSize = 0.008;
    const grid = new Map();

    for (const pt of sorted) {
        const gx = Math.floor(pt.x / cellSize);
        const gy = Math.floor(pt.y / cellSize);
        const key = `${gx},${gy}`;
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
                const key = `${gx + dx},${gy + dy}`;
                const cell = grid.get(key);
                if (cell) {
                    for (const nb of cell) {
                        if (nb.idx !== pt.idx) neighbors.push(nb);
                    }
                }
            }
        }

        neighbors.sort((a, b) => {
            const da = (a.x - pt.x) ** 2 + (a.y - pt.y) ** 2;
            const db = (b.x - pt.x) ** 2 + (b.y - pt.y) ** 2;
            return da - db;
        });

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
                    const maxEdge = Math.max(
                        Math.sqrt(e1x * e1x + e1y * e1y),
                        Math.sqrt(e2x * e2x + e2y * e2y),
                        Math.sqrt((p2.x-p1.x)**2 + (p2.y-p1.y)**2)
                    );
                    if (area > 1e-8 && maxEdge < cellSize * 3) {
                        seen.add(key);
                        indices.push(tri[0], tri[1], tri[2]);
                    }
                }
            }
        }
    }

    console.log(`[Fallback] Generated ${indices.length / 3} triangles`);
    return indices.length > 0 ? indices : null;
}

/**
 * Compute per-vertex normals from triangles.
 */
function computeNormals(landmarks) {
    const normals = landmarks.map(() => ({ x: 0, y: 0, z: 0 }));

    if (triangleIndices) {
        for (let t = 0; t < triangleIndices.length; t += 3) {
            const i0 = triangleIndices[t];
            const i1 = triangleIndices[t + 1];
            const i2 = triangleIndices[t + 2];

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
            const dx = landmarks[i].x - cx;
            const dy = landmarks[i].y - cy;
            const dz = landmarks[i].z - cz;
            const len = Math.sqrt(dx*dx + dy*dy + dz*dz);
            normals[i] = { x: dx/len, y: dy/len, z: dz/len };
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

    console.log(`[Viewer] Init canvas: ${w}x${h}`);

    scene = new THREE.Scene();

    // Gradient background
    scene.background = new THREE.Color(0x1a1a2e);

    // Camera
    threeCamera = new THREE.PerspectiveCamera(45, w / h, 0.001, 10);
    threeCamera.position.set(0, 0, 0.35);

    // Renderer
    renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false });
    renderer.setSize(w, h);
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.2;
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    container.appendChild(renderer.domElement);

    // Controls
    controls = new OrbitControls(threeCamera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.08;
    controls.target.set(0, 0, 0);
    controls.minDistance = 0.05;
    controls.maxDistance = 2;
    controls.enablePan = true;

    // Lighting — optimized for face texture rendering
    // Key light (main illumination from front-right)
    const keyLight = new THREE.DirectionalLight(0xffffff, 2.0);
    keyLight.position.set(0.3, 0.4, 1);
    scene.add(keyLight);

    // Fill light (softer, from front-left, to reduce shadows)
    const fillLight = new THREE.DirectionalLight(0xe8e8ff, 1.0);
    fillLight.position.set(-0.4, 0.2, 0.8);
    scene.add(fillLight);

    // Top light (subtle overhead)
    const topLight = new THREE.DirectionalLight(0xffffff, 0.5);
    topLight.position.set(0, 1, 0.3);
    scene.add(topLight);

    // Rim light from behind (subtle edge definition)
    const rimLight = new THREE.DirectionalLight(0xffddcc, 0.3);
    rimLight.position.set(0, -0.2, -0.5);
    scene.add(rimLight);

    // Strong ambient + hemisphere for even base illumination
    scene.add(new THREE.AmbientLight(0xffffff, 0.6));
    scene.add(new THREE.HemisphereLight(0xffeedd, 0x444466, 0.5));

    // Resize handler
    const resizeViewer = () => {
        const rw = container.clientWidth;
        const rh = container.clientHeight;
        if (rw > 0 && rh > 0) {
            threeCamera.aspect = rw / rh;
            threeCamera.updateProjectionMatrix();
            renderer.setSize(rw, rh);
        }
    };
    window.addEventListener('resize', resizeViewer);

    if (typeof ResizeObserver !== 'undefined') {
        const ro = new ResizeObserver(() => resizeViewer());
        ro.observe(container);
    }

    // Render loop
    function animate() {
        requestAnimationFrame(animate);
        controls.update();
        renderer.render(scene, threeCamera);
    }
    animate();

    console.log('[Viewer] Three.js scene initialized');
}

/**
 * Auto-center and fit the camera to show the face mesh.
 */
function autoCenterCamera() {
    if (!baseLandmarks || !threeCamera || !controls) return;

    let minX = Infinity, maxX = -Infinity;
    let minY = Infinity, maxY = -Infinity;
    let minZ = Infinity, maxZ = -Infinity;

    for (const lm of baseLandmarks) {
        minX = Math.min(minX, lm.x); maxX = Math.max(maxX, lm.x);
        minY = Math.min(minY, lm.y); maxY = Math.max(maxY, lm.y);
        minZ = Math.min(minZ, lm.z); maxZ = Math.max(maxZ, lm.z);
    }

    const cx = (minX + maxX) / 2;
    const cy = (minY + maxY) / 2;
    const cz = (minZ + maxZ) / 2;

    const sizeX = maxX - minX;
    const sizeY = maxY - minY;
    const maxSize = Math.max(sizeX, sizeY);

    const fovRad = threeCamera.fov * (Math.PI / 180);
    const distance = (maxSize / 2) / Math.tan(fovRad / 2) * 1.5;

    threeCamera.position.set(cx, cy, cz + Math.max(distance, 0.15));
    controls.target.set(cx, cy, cz);
    controls.update();

    console.log(`[Camera] Auto-centered — center: (${cx.toFixed(4)}, ${cy.toFixed(4)}, ${cz.toFixed(4)}), dist: ${distance.toFixed(4)}`);
}

/**
 * Build or update the 3D face mesh with healing deformation applied.
 * If a camera texture was captured, it is UV-mapped onto the mesh.
 * Healing effects (bruising, swelling) are blended via vertex colors.
 */
function buildFaceMesh(day) {
    if (!baseLandmarks || !zoneWeights) return;

    const state = healingModel.evaluate(day);
    const hasTexture = capturedTexture && capturedUVs;

    // Remove previous mesh
    if (faceMesh) {
        scene.remove(faceMesh);
        faceMesh.geometry.dispose();
        faceMesh.material.dispose();
        faceMesh = null;
    }

    // Also remove point cloud if exists
    const oldPoints = scene.getObjectByName('pointCloud');
    if (oldPoints) { scene.remove(oldPoints); oldPoints.geometry.dispose(); }

    const positions = new Float32Array(baseLandmarks.length * 3);
    const normals3 = new Float32Array(baseLandmarks.length * 3);
    const colors = new Float32Array(baseLandmarks.length * 3);
    const uvs = new Float32Array(baseLandmarks.length * 2);

    const displacementM = state.nasalVolumeDelta / 1000; // mm -> meters

    // Skin base color (used when no texture or in demo mode)
    const skinR = 0.85, skinG = 0.72, skinB = 0.62;

    for (let i = 0; i < baseLandmarks.length; i++) {
        const lm = baseLandmarks[i];
        const n = faceNormals[i];
        const zw = zoneWeights[i];

        // ── Swelling deformation ──
        const swellW = FaceZones.getSwellingWeight(zw);
        const dx = n.x * displacementM * swellW;
        const dy = n.y * displacementM * swellW;
        const dz = n.z * displacementM * swellW;

        positions[i * 3]     = lm.x + dx;
        positions[i * 3 + 1] = lm.y + dy;
        positions[i * 3 + 2] = lm.z + dz;

        normals3[i * 3]     = n.x;
        normals3[i * 3 + 1] = n.y;
        normals3[i * 3 + 2] = n.z;

        // ── UV coordinates (from original 2D landmark positions) ──
        if (capturedUVs) {
            uvs[i * 2]     = capturedUVs[i].u;
            uvs[i * 2 + 1] = capturedUVs[i].v;
        }

        // ── Vertex colors ──
        // When we have a texture, vertex colors act as a MULTIPLIER on the texture.
        // White (1,1,1) = show texture as-is. Tinted = overlay healing effects.
        let r, g, b;

        if (showZones) {
            // Zone visualization mode: color by zone (overrides texture)
            const [zr, zg, zb] = zw.color || [0.15, 0.15, 0.15];
            const mix = Math.max(0.2, zw.weight);
            r = skinR * (1 - mix) + zr * mix;
            g = skinG * (1 - mix) + zg * mix;
            b = skinB * (1 - mix) + zb * mix;
        } else if (hasTexture) {
            // ── TEXTURE MODE: start white, apply healing tints ──
            r = 1.0; g = 1.0; b = 1.0;

            // Bruise overlay: tint vertex colors toward bruise color
            const bruiseW = FaceZones.getBruisingWeight(zw);
            const bruiseIntensity = state.bruisingLevel * bruiseW;
            if (bruiseIntensity > 0.01) {
                const [br, bg, bb] = state.bruiseColor;
                const strength = bruiseIntensity * 0.65;
                r = r * (1 - strength) + br * strength;
                g = g * (1 - strength) + bg * strength;
                b = b * (1 - strength) + bb * strength;
                // Darken bruised areas
                const darken = 1.0 - bruiseIntensity * 0.2;
                r *= darken; g *= darken; b *= darken;
            }

            // Swelling redness (mild flushing)
            const swellRedness = state.swellingLevel * swellW * 0.08;
            if (swellRedness > 0.01) {
                r = Math.min(1, r + swellRedness * 0.5);
                g = Math.max(0, g - swellRedness * 0.15);
                b = Math.max(0, b - swellRedness * 0.1);
            }
        } else {
            // ── NO TEXTURE (demo mode): use skin vertex colors ──
            r = skinR; g = skinG; b = skinB;

            const bruiseW = FaceZones.getBruisingWeight(zw);
            const bruiseIntensity = state.bruisingLevel * bruiseW;
            if (bruiseIntensity > 0.01) {
                const [br, bg, bb] = state.bruiseColor;
                r = skinR * (1 - bruiseIntensity * 0.7) + br * bruiseIntensity * 0.7;
                g = skinG * (1 - bruiseIntensity * 0.7) + bg * bruiseIntensity * 0.7;
                b = skinB * (1 - bruiseIntensity * 0.7) + bb * bruiseIntensity * 0.7;
                const darken = 1.0 - bruiseIntensity * 0.15;
                r *= darken; g *= darken; b *= darken;
            }

            const swellRedness = state.swellingLevel * swellW * 0.12;
            r = Math.min(1, r + swellRedness);
            g = Math.max(0, g - swellRedness * 0.3);
        }

        colors[i * 3]     = r;
        colors[i * 3 + 1] = g;
        colors[i * 3 + 2] = b;
    }

    // ── Build geometry ──
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    geometry.setAttribute('normal', new THREE.BufferAttribute(normals3, 3));
    geometry.setAttribute('color', new THREE.BufferAttribute(colors, 3));

    if (capturedUVs) {
        geometry.setAttribute('uv', new THREE.BufferAttribute(uvs, 2));
    }

    const hasTriangles = triangleIndices && triangleIndices.length > 0;

    // Determine which triangle indices to use
    let activeIndices = null;
    if (hasTriangles) {
        activeIndices = triangleIndices;
    } else {
        const fallbackIndices = buildFallbackTriangulation(baseLandmarks);
        if (fallbackIndices && fallbackIndices.length > 0) {
            activeIndices = new Uint32Array(fallbackIndices);
        }
    }

    if (activeIndices && activeIndices.length > 0) {
        geometry.setIndex(new THREE.BufferAttribute(activeIndices, 1));
        geometry.computeVertexNormals();

        // Material: texture + vertex colors (vertex colors multiply with texture)
        const useTextureInMaterial = hasTexture && !showZones;

        const material = new THREE.MeshStandardMaterial({
            map: useTextureInMaterial ? capturedTexture : null,
            vertexColors: true,
            roughness: 0.6,
            metalness: 0.0,
            side: THREE.DoubleSide,
            flatShading: !hasTriangles, // flat shading only for fallback triangulation
        });

        faceMesh = new THREE.Mesh(geometry, material);
        faceMesh.name = 'faceMesh';
        scene.add(faceMesh);

        console.log(`[Mesh] Built ${useTextureInMaterial ? 'textured' : 'colored'} mesh with ${activeIndices.length / 3} triangles`);
    }

    // Always add point cloud (visible through mesh edges or standalone)
    const pointGeometry = new THREE.BufferGeometry();
    pointGeometry.setAttribute('position', new THREE.BufferAttribute(positions.slice(), 3));
    pointGeometry.setAttribute('color', new THREE.BufferAttribute(colors.slice(), 3));

    const pointMaterial = new THREE.PointsMaterial({
        size: activeIndices ? 0.001 : 0.004,
        vertexColors: true,
        sizeAttenuation: true,
    });

    const pointCloud = new THREE.Points(pointGeometry, pointMaterial);
    pointCloud.name = 'pointCloud';
    scene.add(pointCloud);

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
        // Reset camera UI from previous error state
        document.getElementById('capture-btn').style.display = '';
        const fallbackBtn = document.getElementById('camera-fallback-btn');
        if (fallbackBtn) fallbackBtn.remove();
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
    else if (d < 365) dayLabel.textContent = `${Math.round(d / 30)} month${Math.round(d/30) > 1 ? 's' : ''}`;
    else dayLabel.textContent = '12 months';

    swellPct.textContent = `${Math.round(state.swellingLevel * 100)}%`;
    swellPct.className = 'stat-value ' + (
        state.swellingLevel > 0.6 ? 'high' :
        state.swellingLevel > 0.3 ? 'med' :
        state.swellingLevel > 0.1 ? 'low' : 'min'
    );

    if (state.bruisingLevel > 0.01) {
        bruiseRow.style.display = 'flex';
        bruisePct.textContent = `${Math.round(state.bruisingLevel * 100)}%`;
        const [br, bg, bb] = state.bruiseColor;
        bruiseDot.style.backgroundColor = `rgb(${Math.round(br*255)},${Math.round(bg*255)},${Math.round(bb*255)})`;
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
        dot.style.backgroundColor = `rgb(${Math.round(r*255)},${Math.round(g*255)},${Math.round(b*255)})`;

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
    // Splash
    document.getElementById('start-btn').addEventListener('click', () => showScreen('scan'));
    document.getElementById('demo-btn').addEventListener('click', useSampleFace);

    // Scan
    document.getElementById('capture-btn').addEventListener('click', captureFace);
    document.getElementById('scan-back-btn').addEventListener('click', () => showScreen('splash'));

    // Viewer
    document.getElementById('viewer-back-btn').addEventListener('click', () => {
        showScreen('splash');
        // cleanup
        if (faceMesh) { scene.remove(faceMesh); }
        baseLandmarks = null;
        // Dispose texture
        if (capturedTexture) {
            capturedTexture.dispose();
            capturedTexture = null;
        }
        capturedUVs = null;
    });

    // Timeline slider
    const slider = document.getElementById('timeline-slider');
    slider.addEventListener('input', (e) => {
        setDay(parseFloat(e.target.value));
    });

    // Preset buttons
    document.querySelectorAll('.preset-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            const day = parseFloat(btn.dataset.day);
            setDay(day);
            // Highlight active preset
            document.querySelectorAll('.preset-btn').forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
        });
    });

    // Settings
    document.getElementById('opt-skin').addEventListener('change', updateProfile);
    document.getElementById('opt-intensity').addEventListener('change', updateProfile);
    document.getElementById('opt-bruising').addEventListener('change', updateProfile);

    // Zone toggle
    document.getElementById('zone-toggle').addEventListener('change', (e) => {
        showZones = e.target.checked;
        buildFaceMesh(currentDay);
        document.getElementById('zone-legend').style.display = showZones ? 'block' : 'none';
    });

    // Disclaimer
    document.getElementById('disclaimer-ok').addEventListener('click', () => {
        document.getElementById('disclaimer-modal').style.display = 'none';
    });

    // Build zone legend
    buildZoneLegend();

    // Init MediaPipe
    initMediaPipe();
}

document.addEventListener('DOMContentLoaded', init);
