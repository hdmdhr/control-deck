import * as THREE from './three.module.min.js';

const canvas = document.querySelector('#viewport');
const timerElement = document.querySelector('#timer');
const bestElement = document.querySelector('#best-time');
const courseElement = document.querySelector('#course-number');
const seedElement = document.querySelector('#seed-label');
const statusElement = document.querySelector('#status');
const startButton = document.querySelector('#start-button');
const toastElement = document.querySelector('#toast');

const messages = window.controlDeckGameStrings || {};
const text = (key, fallback) => messages[key] || fallback;
document.querySelector('.course-panel .hud-label').textContent = text('course', 'COURSE');
document.querySelector('.best-panel .hud-label').textContent = text('best', 'BEST');
document.querySelector('#game').setAttribute('aria-label', text('title', 'Tilt Run'));
document.title = text('title', 'Tilt Run');

const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFShadowMap;
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.08;

const scene = new THREE.Scene();
scene.fog = new THREE.Fog(0xb8d7ff, 42, 125);

const camera = new THREE.PerspectiveCamera(58, 1, 0.1, 180);
camera.position.set(0, 5.6, 9.5);

scene.add(new THREE.HemisphereLight(0xffffff, 0x6676c5, 2.5));
const sun = new THREE.DirectionalLight(0xffffff, 4.2);
sun.position.set(-8, 18, 10);
sun.castShadow = true;
sun.shadow.mapSize.set(2048, 2048);
sun.shadow.camera.left = -28;
sun.shadow.camera.right = 28;
sun.shadow.camera.top = 28;
sun.shadow.camera.bottom = -28;
scene.add(sun);

const palette = {
  platform: 0xf4f5ff,
  platformSide: 0x5367c9,
  rail: 0x195bbd,
  coral: 0xff6e67,
  lime: 0xbce934,
  cyan: 0x4bd8ff,
  cobalt: 0x076af1
};

const platformMaterial = new THREE.MeshStandardMaterial({
  color: 0xe9ebf8,
  roughness: 0.48,
  metalness: 0.05
});
const sideMaterial = new THREE.MeshStandardMaterial({
  color: palette.platformSide,
  roughness: 0.4
});
const railMaterial = new THREE.MeshStandardMaterial({
  color: palette.rail,
  roughness: 0.34,
  metalness: 0.08
});
const markingMaterial = new THREE.MeshStandardMaterial({
  color: 0x8aa7ec,
  roughness: 0.42,
  emissive: 0x14386f,
  emissiveIntensity: 0.06
});
const coralMaterial = new THREE.MeshStandardMaterial({
  color: palette.coral,
  roughness: 0.32
});
const limeMaterial = new THREE.MeshStandardMaterial({
  color: palette.lime,
  roughness: 0.28,
  emissive: 0x446400,
  emissiveIntensity: 0.18
});

let courseGroup = new THREE.Group();
let environmentGroup = new THREE.Group();
scene.add(courseGroup);
scene.add(environmentGroup);
let segments = [];
let bumpers = [];
let gates = [];
let tokens = [];
let goal = { x: 0, z: -80 };
let startPosition = new THREE.Vector3(0, 0.52, 1.4);
let checkpoint = startPosition.clone();
let currentSeed = 8127;

const ballRadius = 0.58;
const ball = new THREE.Mesh(
  new THREE.SphereGeometry(ballRadius, 40, 28),
  new THREE.MeshPhysicalMaterial({
    color: palette.cobalt,
    roughness: 0.12,
    metalness: 0.06,
    clearcoat: 1,
    clearcoatRoughness: 0.12
  })
);
ball.castShadow = true;
ball.receiveShadow = true;
scene.add(ball);

const ballVelocity = new THREE.Vector3();
let verticalVelocity = 0;
let tiltX = 0;
let tiltY = 0;
let playing = false;
let finished = false;
let startTime = 0;
let elapsedBeforeStart = 0;
let penaltyMilliseconds = 0;
let bestMilliseconds = 0;
let lastFrameTime = performance.now();
let toastTimeout = 0;
const courseTiltPivot = new THREE.Vector3();
const courseTiltRotatedPivot = new THREE.Vector3();

function mulberry32(seed) {
  let value = seed >>> 0;
  return () => {
    value += 0x6D2B79F5;
    let result = value;
    result = Math.imul(result ^ (result >>> 15), result | 1);
    result ^= result + Math.imul(result ^ (result >>> 7), result | 61);
    return ((result ^ (result >>> 14)) >>> 0) / 4294967296;
  };
}

function disposeGroup(group) {
  group.traverse((object) => {
    if (object.geometry) object.geometry.dispose();
    if (object.material && ![
      platformMaterial, sideMaterial, railMaterial, markingMaterial,
      coralMaterial, limeMaterial
    ].includes(object.material)) object.material.dispose();
  });
  scene.remove(group);
}

function addBox(width, height, length, material, x, y, z, parent = courseGroup) {
  const mesh = new THREE.Mesh(new THREE.BoxGeometry(width, height, length), material);
  mesh.position.set(x, y, z);
  mesh.castShadow = true;
  mesh.receiveShadow = true;
  parent.add(mesh);
  return mesh;
}

function buildCourse(seed) {
  disposeGroup(courseGroup);
  disposeGroup(environmentGroup);
  courseGroup = new THREE.Group();
  environmentGroup = new THREE.Group();
  scene.add(courseGroup);
  scene.add(environmentGroup);
  segments = [];
  bumpers = [];
  gates = [];
  tokens = [];
  currentSeed = Math.abs(Math.trunc(seed || 8127)) % 10000;
  const random = mulberry32(currentSeed);
  let x = 0;
  const segmentCount = 17;

  for (let index = 0; index < segmentCount; index += 1) {
    const width = index === 0 ? 7.4 : 5.3 + random() * 2.4;
    const length = index === segmentCount - 1 ? 6.8 : 5.0;
    if (index > 1) x += (random() - 0.5) * 2.25;
    x = THREE.MathUtils.clamp(x, -5.2, 5.2);
    const z = 1.0 - index * 4.78;
    const segment = { x, z, width, length, index };
    segments.push(segment);

    addBox(width + 0.16, 0.58, length + 0.16, sideMaterial, x, -0.33, z);
    addBox(width, 0.24, length, platformMaterial, x, -0.04, z);
    for (let marker = -1; marker <= 1; marker += 1) {
      addBox(
        width * 0.82, 0.018, 0.032, markingMaterial,
        x, 0.088, z + marker * length * 0.25
      );
    }

    if (index > 0 && index < segmentCount - 1 && random() > 0.48) {
      const side = random() > 0.5 ? 1 : -1;
      addBox(
        0.18, 0.42, length * 0.74, railMaterial,
        x + side * (width / 2 - 0.09), 0.25, z
      );
      const markerCount = 3;
      for (let marker = 0; marker < markerCount; marker += 1) {
        addBox(
          0.24, 0.16, 0.52, coralMaterial,
          x + side * (width / 2 - 0.09), 0.51,
          z - length * 0.25 + marker * length * 0.25
        );
      }
    }

    if ([3, 7, 11].includes(index)) {
      const bumperX = x + (random() - 0.5) * Math.max(1, width - 2.1);
      const bumper = new THREE.Mesh(
        new THREE.CylinderGeometry(0.52, 0.62, 0.72, 24),
        coralMaterial
      );
      bumper.position.set(bumperX, 0.36, z);
      bumper.castShadow = true;
      courseGroup.add(bumper);
      bumpers.push({ mesh: bumper, radius: 0.62 });
    }

    if ([5, 13].includes(index)) {
      const gate = addBox(width * 0.54, 0.42, 0.30, coralMaterial, x, 0.30, z);
      gates.push({ mesh: gate, centerX: x, range: width * 0.23, speed: 1.0 + random() });
    }

    if ([2, 6, 10, 14].includes(index)) {
      const token = new THREE.Mesh(
        new THREE.TorusGeometry(0.34, 0.12, 12, 28),
        limeMaterial
      );
      token.position.set(x + (random() - 0.5) * (width - 1.5), 0.76, z);
      token.castShadow = true;
      courseGroup.add(token);
      tokens.push({ mesh: token, collected: false });
    }
  }

  const first = segments[0];
  const last = segments[segments.length - 1];
  startPosition = new THREE.Vector3(first.x, ballRadius + 0.12, first.z + 1.2);
  checkpoint = startPosition.clone();
  goal = { x: last.x, z: last.z - 0.6 };

  const goalRing = new THREE.Mesh(
    new THREE.TorusGeometry(1.25, 0.17, 18, 48),
    new THREE.MeshStandardMaterial({
      color: 0xffdd62,
      emissive: 0xffa700,
      emissiveIntensity: 1.8,
      roughness: 0.24
    })
  );
  goalRing.position.set(goal.x, 1.27, goal.z);
  goalRing.castShadow = true;
  courseGroup.add(goalRing);

  for (let index = 0; index < 22; index += 1) {
    const cloud = new THREE.Mesh(
      new THREE.SphereGeometry(1.2 + random() * 2.2, 16, 10),
      new THREE.MeshStandardMaterial({
        color: index % 4 === 0 ? 0x9aaef0 : 0xffffff,
        transparent: true,
        opacity: index % 4 === 0 ? 0.18 : 0.48,
        roughness: 1
      })
    );
    cloud.scale.y = 0.38 + random() * 0.18;
    cloud.position.set((random() - 0.5) * 65, -5 - random() * 9, -random() * 95 + 14);
    environmentGroup.add(cloud);
  }

  for (let index = 0; index < 14; index += 1) {
    const towerHeight = 3.5 + random() * 8.5;
    const tower = addBox(
      1.1 + random() * 1.9,
      towerHeight,
      1.1 + random() * 1.9,
      new THREE.MeshStandardMaterial({
        color: index % 3 === 0 ? 0x8da7eb : 0xdde6ff,
        roughness: 0.76
      }),
      (random() > 0.5 ? 1 : -1) * (10 + random() * 20),
      -4.5 - random() * 3,
      8 - random() * 100,
      environmentGroup
    );
    tower.rotation.y = random() * 0.35;
  }

  courseElement.textContent = String((currentSeed % 99) + 1).padStart(2, '0');
  seedElement.textContent = `${text('seed', 'SEED')} ${String(currentSeed).padStart(4, '0')}`;
  resetBall();
}

function platformAt(x, z) {
  return segments.find((segment) =>
    Math.abs(x - segment.x) <= segment.width / 2 - 0.12 &&
    Math.abs(z - segment.z) <= segment.length / 2 + 0.08
  );
}

function resetBall() {
  ball.position.copy(checkpoint);
  ballVelocity.set(0, 0, 0);
  verticalVelocity = 0;
  camera.position.set(ball.position.x, 4.45, ball.position.z + 7.1);
}

function showToast(message) {
  toastElement.textContent = message;
  toastElement.classList.add('visible');
  window.clearTimeout(toastTimeout);
  toastTimeout = window.setTimeout(() => toastElement.classList.remove('visible'), 1150);
}

function formatTime(milliseconds) {
  if (!Number.isFinite(milliseconds) || milliseconds <= 0) return '--:--.--';
  const totalHundredths = Math.floor(milliseconds / 10);
  const hundredths = totalHundredths % 100;
  const totalSeconds = Math.floor(totalHundredths / 100);
  const seconds = totalSeconds % 60;
  const minutes = Math.floor(totalSeconds / 60);
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}.${String(hundredths).padStart(2, '0')}`;
}

function elapsedMilliseconds(now = performance.now()) {
  return elapsedBeforeStart + (playing ? now - startTime : 0) + penaltyMilliseconds;
}

function postToNative(message) {
  const handler = window.webkit?.messageHandlers?.gyroGame;
  if (!handler) return false;
  handler.postMessage(message);
  return true;
}

function startRun(seed, best = 0) {
  if (seed !== currentSeed) buildCourse(seed);
  bestMilliseconds = Number(best) || 0;
  bestElement.textContent = formatTime(bestMilliseconds);
  checkpoint = startPosition.clone();
  tokens.forEach((token) => {
    token.collected = false;
    token.mesh.visible = true;
  });
  finished = false;
  playing = true;
  elapsedBeforeStart = 0;
  penaltyMilliseconds = 0;
  startTime = performance.now();
  resetBall();
  statusElement.classList.add('hidden');
}

function stopRun() {
  if (playing) elapsedBeforeStart += performance.now() - startTime;
  playing = false;
  statusElement.classList.remove('hidden');
  statusElement.querySelector('strong').textContent = finished ? text('clear', 'COURSE CLEAR') : text('title', 'TILT RUN');
  statusElement.querySelector('span').textContent = finished
    ? formatTime(elapsedMilliseconds())
    : text('hint', 'Tilt the controller to roll');
  startButton.textContent = finished ? text('again', 'RUN AGAIN') : text('start', 'START RUN');
}

function resetRun() {
  checkpoint = startPosition.clone();
  tokens.forEach((token) => {
    token.collected = false;
    token.mesh.visible = true;
  });
  finished = false;
  elapsedBeforeStart = 0;
  penaltyMilliseconds = 0;
  startTime = performance.now();
  timerElement.textContent = '00:00.00';
  resetBall();
}

function finishRun() {
  if (!playing || finished) return;
  const result = elapsedMilliseconds();
  elapsedBeforeStart = Math.max(0, result - penaltyMilliseconds);
  playing = false;
  finished = true;
  timerElement.textContent = formatTime(result);
  if (!bestMilliseconds || result < bestMilliseconds) {
    bestMilliseconds = result;
    bestElement.textContent = formatTime(result);
  }
  showToast(text('clear', 'COURSE CLEAR!'));
  postToNative({ type: 'finish', elapsedMilliseconds: result, seed: currentSeed });
  window.setTimeout(stopRun, 550);
}

function collideObstacles() {
  for (const bumper of bumpers) {
    const offsetX = ball.position.x - bumper.mesh.position.x;
    const offsetZ = ball.position.z - bumper.mesh.position.z;
    const distance = Math.hypot(offsetX, offsetZ);
    const minimum = ballRadius + bumper.radius;
    if (distance < minimum && distance > 0.001) {
      const nx = offsetX / distance;
      const nz = offsetZ / distance;
      ball.position.x = bumper.mesh.position.x + nx * minimum;
      ball.position.z = bumper.mesh.position.z + nz * minimum;
      const speed = ballVelocity.x * nx + ballVelocity.z * nz;
      if (speed < 0) {
        ballVelocity.x -= 1.65 * speed * nx;
        ballVelocity.z -= 1.65 * speed * nz;
      }
    }
  }

  for (const gate of gates) {
    const halfWidth = gate.mesh.geometry.parameters.width / 2;
    if (
      Math.abs(ball.position.x - gate.mesh.position.x) < halfWidth + ballRadius &&
      Math.abs(ball.position.z - gate.mesh.position.z) < 0.25 + ballRadius
    ) {
      const direction = ball.position.z >= gate.mesh.position.z ? 1 : -1;
      ball.position.z = gate.mesh.position.z + direction * (0.25 + ballRadius);
      ballVelocity.z *= -0.48;
    }
  }
}

function updatePhysics(delta, now) {
  if (!playing || finished) return;
  const acceleration = 7.8;
  ballVelocity.x += tiltX * acceleration * delta;
  ballVelocity.z -= tiltY * acceleration * delta;
  const damping = Math.pow(0.32, delta);
  ballVelocity.x *= damping;
  ballVelocity.z *= damping;
  const planarSpeed = Math.hypot(ballVelocity.x, ballVelocity.z);
  if (planarSpeed > 8.5) {
    const scale = 8.5 / planarSpeed;
    ballVelocity.x *= scale;
    ballVelocity.z *= scale;
  }

  const previousX = ball.position.x;
  const previousZ = ball.position.z;
  ball.position.x += ballVelocity.x * delta;
  ball.position.z += ballVelocity.z * delta;
  const platform = platformAt(ball.position.x, ball.position.z);

  if (platform) {
    ball.position.y = ballRadius + 0.12;
    verticalVelocity = 0;
    if (platform.index > 0 && platform.index % 4 === 0) {
      checkpoint.set(platform.x, ballRadius + 0.12, platform.z + 1.2);
    }
    collideObstacles();
  } else {
    verticalVelocity -= 10.5 * delta;
    ball.position.y += verticalVelocity * delta;
    if (ball.position.y < -6) {
      penaltyMilliseconds += 2000;
      resetBall();
      showToast(text('saved', '+2 SEC · BALL SAVED'));
      postToNative({ type: 'fall' });
    }
  }

  const movementX = ball.position.x - previousX;
  const movementZ = ball.position.z - previousZ;
  ball.rotation.z -= movementX / ballRadius;
  ball.rotation.x += movementZ / ballRadius;

  for (const token of tokens) {
    token.mesh.rotation.y += delta * 2.6;
    token.mesh.rotation.z = Math.sin(now * 0.002) * 0.12;
    if (!token.collected && token.mesh.position.distanceTo(ball.position) < 0.92) {
      token.collected = true;
      token.mesh.visible = false;
      penaltyMilliseconds = Math.max(0, penaltyMilliseconds - 1000);
      showToast(text('token', '-1 SEC'));
      postToNative({ type: 'token' });
    }
  }

  for (const gate of gates) {
    gate.mesh.position.x = gate.centerX + Math.sin(now * 0.001 * gate.speed) * gate.range;
  }

  if (Math.hypot(ball.position.x - goal.x, ball.position.z - goal.z) < 1.1) {
    finishRun();
  }

  timerElement.textContent = formatTime(elapsedMilliseconds(now));
}

function updateCamera(delta) {
  const desired = new THREE.Vector3(
    ball.position.x - tiltX * 1.15,
    Math.max(4.0, ball.position.y + 4.15),
    ball.position.z + 6.8
  );
  camera.position.lerp(desired, 1 - Math.pow(0.012, delta));
  camera.lookAt(ball.position.x, ball.position.y + 0.10, ball.position.z - 3.5);
  camera.rotation.z = THREE.MathUtils.lerp(camera.rotation.z, -tiltX * 0.035, 0.08);
}

function updateCourseTilt(delta) {
  const response = 1 - Math.pow(0.0008, delta);
  const maximumTilt = 0.18;
  courseGroup.rotation.x = THREE.MathUtils.lerp(
    courseGroup.rotation.x,
    -tiltY * maximumTilt,
    response
  );
  courseGroup.rotation.z = THREE.MathUtils.lerp(
    courseGroup.rotation.z,
    -tiltX * maximumTilt,
    response
  );

  // Rotate the stage about the point directly beneath the ball. This keeps
  // the contact patch visually stable while the rest of the course banks.
  courseTiltPivot.set(ball.position.x, 0, ball.position.z);
  courseTiltRotatedPivot.copy(courseTiltPivot).applyEuler(courseGroup.rotation);
  courseGroup.position.copy(courseTiltPivot).sub(courseTiltRotatedPivot);
}

function resize() {
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;
  if (!width || !height) return;
  const needsResize = canvas.width !== Math.floor(width * renderer.getPixelRatio()) ||
    canvas.height !== Math.floor(height * renderer.getPixelRatio());
  if (needsResize) {
    renderer.setSize(width, height, false);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
  }
}

function animate(now) {
  const delta = Math.min(Math.max((now - lastFrameTime) / 1000, 0), 0.033);
  lastFrameTime = now;
  resize();
  updateCourseTilt(delta);
  updatePhysics(delta, now);
  updateCamera(delta);
  renderer.render(scene, camera);
}

startButton.addEventListener('click', () => {
  // Start locally first so this control always gives immediate feedback. The
  // native message then activates ControlDeck's gyro-game mode and pauses
  // normal gesture actions; its mirrored start command is idempotent below.
  startRun(currentSeed, bestMilliseconds);
  postToNative({ type: 'start' });
});
window.addEventListener('keydown', (event) => {
  if (event.key === 'ArrowLeft') tiltX = -0.72;
  if (event.key === 'ArrowRight') tiltX = 0.72;
  if (event.key === 'ArrowUp') tiltY = 0.72;
  if (event.key === 'ArrowDown') tiltY = -0.72;
});
window.addEventListener('keyup', (event) => {
  if (event.key.startsWith('Arrow')) {
    tiltX = 0;
    tiltY = 0;
  }
});

window.controlDeckGame = {
  isPlaying() {
    return playing;
  },
  setMotion(x, y) {
    tiltX = THREE.MathUtils.clamp(Number(x) || 0, -1, 1);
    tiltY = THREE.MathUtils.clamp(Number(y) || 0, -1, 1);
  },
  setCourse(seed) {
    if (!playing) buildCourse(seed);
  },
  start(seed, best) {
    if (playing && Number(seed) === currentSeed) {
      bestMilliseconds = Number(best) || 0;
      bestElement.textContent = formatTime(bestMilliseconds);
      return;
    }
    startRun(seed, best);
  },
  reset() {
    resetRun();
  },
  stop() {
    stopRun();
  },
  setBest(best) {
    bestMilliseconds = Number(best) || 0;
    bestElement.textContent = formatTime(bestMilliseconds);
  }
};

buildCourse(currentSeed);
stopRun();
renderer.setAnimationLoop(animate);
postToNative({ type: 'ready' });
