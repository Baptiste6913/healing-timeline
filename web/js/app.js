/**
 * app.js — Main application: MediaPipe face capture + Three.js 3D viewer + timeline.
 *
 * ES Module. Imports Three.js and MediaPipe from CDN.
 * Uses FaceZones and HealingModelJS from global scope (loaded via script tags).
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

        // Extract tesselation for mesh building
        if (FaceLandmarker.FACE_LANDMARKS_TESSELATION) {
            buildTrianglesFromEdges(FaceLandmarker.FACE_LANDMARKS_TESSELATION);
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
        document.getElementById('scan-instruction').textContent = 'Camera access denied. Please allow camera.';
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

    // Stop camera
    if (videoStream) {
        videoStream.getTracks().forEach(t => t.stop());
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

        // Build and show viewer
        initViewer();
        buildFaceMesh(0);
        showScreen('viewer');
    }, 500);
}

/**
 * Use sample/generated face for demo mode (no camera needed).
 */
function useSampleFace() {
    showScreen('processing');

    setTimeout(() => {
        baseLandmarks = generateSampleFaceLandmarks();
        zoneWeights = FaceZones.computeZoneWeights(baseLandmarks);
        faceNormals = computeNormals(baseLandmarks);

        initViewer();
        buildFaceMesh(0);
        showScreen('viewer');
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

            // edge vectors
            const e1x = v1.x - v0.x, e1y = v1.y - v0.y, e1z = v1.z - v0.z;
            const e2x = v2.x - v0.x, e2y = v2.y - v0.y, e2z = v2.z - v0.z;

            // cross product
            const nx = e1y * e2z - e1z * e2y;
            const ny = e1z * e2x - e1x * e2z;
            const nz = e1x * e2y - e1y * e2x;

            normals[i0].x += nx; normals[i0].y += ny; normals[i0].z += nz;
            normals[i1].x += nx; normals[i1].y += ny; normals[i1].z += nz;
            normals[i2].x += nx; normals[i2].y += ny; normals[i2].z += nz;
        }

        // Normalize
        for (const n of normals) {
            const len = Math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
            if (len > 1e-8) { n.x /= len; n.y /= len; n.z /= len; }
            else { n.x = 0; n.y = 0; n.z = 1; }
        }
    } else {
        // Fallback: approximate normals pointing outward from centroid
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
    // Clear previous
    while (container.firstChild) container.removeChild(container.firstChild);

    scene = new THREE.Scene();
    scene.background = new THREE.Color(0x111111);

    // Camera
    threeCamera = new THREE.PerspectiveCamera(45, container.clientWidth / container.clientHeight, 0.001, 10);
    threeCamera.position.set(0, 0, 0.3);

    // Renderer
    renderer = new THREE.WebGLRenderer({ antialias: true });
    renderer.setSize(container.clientWidth, container.clientHeight);
    renderer.setPixelRatio(window.devicePixelRatio);
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.2;
    container.appendChild(renderer.domElement);

    // Controls
    controls = new OrbitControls(threeCamera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.08;
    controls.target.set(0, 0, 0);
    controls.minDistance = 0.1;
    controls.maxDistance = 1;

    // Lights
    const keyLight = new THREE.DirectionalLight(0xffffff, 2.5);
    keyLight.position.set(0.3, 0.5, 1);
    scene.add(keyLight);

    const fillLight = new THREE.DirectionalLight(0xaabbff, 0.8);
    fillLight.position.set(-0.5, 0.2, 0.5);
    scene.add(fillLight);

    const rimLight = new THREE.DirectionalLight(0xffddcc, 0.5);
    rimLight.position.set(0, -0.3, -0.5);
    scene.add(rimLight);

    scene.add(new THREE.AmbientLight(0x333333, 0.5));

    // Resize handler
    window.addEventListener('resize', () => {
        const w = container.clientWidth;
        const h = container.clientHeight;
        threeCamera.aspect = w / h;
        threeCamera.updateProjectionMatrix();
        renderer.setSize(w, h);
    });

    // Render loop
    function animate() {
        requestAnimationFrame(animate);
        controls.update();
        renderer.render(scene, threeCamera);
    }
    animate();
}

/**
 * Build or update the 3D face mesh with healing deformation applied.
 */
function buildFaceMesh(day) {
    if (!baseLandmarks || !zoneWeights) return;

    const state = healingModel.evaluate(day);

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

    const displacementM = state.nasalVolumeDelta / 1000; // mm -> meters

    // Skin base color
    const skinR = 0.85, skinG = 0.72, skinB = 0.62;

    for (let i = 0; i < baseLandmarks.length; i++) {
        const lm = baseLandmarks[i];
        const n = faceNormals[i];
        const zw = zoneWeights[i];

        // Swelling deformation
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

        // Vertex color: skin + bruise blend + zone visualization
        let r = skinR, g = skinG, b = skinB;

        if (showZones) {
            // Zone visualization mode: color by zone
            const [zr, zg, zb] = zw.color || [0.15, 0.15, 0.15];
            const mix = Math.max(0.2, zw.weight);
            r = skinR * (1 - mix) + zr * mix;
            g = skinG * (1 - mix) + zg * mix;
            b = skinB * (1 - mix) + zb * mix;
        } else {
            // Bruise color blending
            const bruiseW = FaceZones.getBruisingWeight(zw);
            const bruiseIntensity = state.bruisingLevel * bruiseW;
            if (bruiseIntensity > 0.01) {
                const [br, bg, bb] = state.bruiseColor;
                r = skinR * (1 - bruiseIntensity * 0.7) + br * bruiseIntensity * 0.7;
                g = skinG * (1 - bruiseIntensity * 0.7) + bg * bruiseIntensity * 0.7;
                b = skinB * (1 - bruiseIntensity * 0.7) + bb * bruiseIntensity * 0.7;
                // Darken in bruised area
                const darken = 1.0 - bruiseIntensity * 0.15;
                r *= darken; g *= darken; b *= darken;
            }

            // Swelling redness (mild flushing in swollen areas)
            const swellRedness = state.swellingLevel * swellW * 0.12;
            r = Math.min(1, r + swellRedness);
            g = Math.max(0, g - swellRedness * 0.3);
        }

        colors[i * 3]     = r;
        colors[i * 3 + 1] = g;
        colors[i * 3 + 2] = b;
    }

    // Build geometry
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    geometry.setAttribute('normal', new THREE.BufferAttribute(normals3, 3));
    geometry.setAttribute('color', new THREE.BufferAttribute(colors, 3));

    if (triangleIndices && triangleIndices.length > 0) {
        // Solid mesh with triangles
        geometry.setIndex(new THREE.BufferAttribute(triangleIndices, 1));

        const material = new THREE.MeshStandardMaterial({
            vertexColors: true,
            roughness: 0.65,
            metalness: 0.0,
            side: THREE.DoubleSide,
            flatShading: false,
        });

        faceMesh = new THREE.Mesh(geometry, material);
        faceMesh.name = 'faceMesh';
        scene.add(faceMesh);
    }

    // Always add point cloud (visible through mesh or standalone)
    const pointGeometry = new THREE.BufferGeometry();
    pointGeometry.setAttribute('position', new THREE.BufferAttribute(positions.slice(), 3));
    pointGeometry.setAttribute('color', new THREE.BufferAttribute(colors.slice(), 3));

    const pointMaterial = new THREE.PointsMaterial({
        size: triangleIndices ? 0.001 : 0.003,
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
