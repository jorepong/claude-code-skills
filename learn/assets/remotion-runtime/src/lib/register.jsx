import React from 'react';
import {createRoot} from 'react-dom/client';
import {Player} from '@remotion/player';

const VISUAL_ID = /^[A-Za-z][A-Za-z0-9_-]*$/;

const assertComposition = (name, def) => {
  if (!/^[A-Za-z0-9_-]+$/.test(name)) {
    throw new Error(`잘못된 Composition ID: ${name}`);
  }
  for (const key of ['component', 'durationInFrames', 'fps', 'width', 'height']) {
    if (def[key] === undefined || def[key] === null) {
      throw new Error(`${name} 등록에 ${key}가 없습니다.`);
    }
  }
  if (!Number.isInteger(def.durationInFrames) || def.durationInFrames <= 0) {
    throw new Error(`${name} durationInFrames는 양의 정수여야 합니다.`);
  }
  const timeline = def.timeline ?? {};
  let previous = -1;
  for (const [stage, frame] of Object.entries(timeline)) {
    if (!/^[A-Za-z][A-Za-z0-9_-]*$/.test(stage)) {
      throw new Error(`${name}의 잘못된 timeline stage-id: ${stage}`);
    }
    if (!Number.isFinite(frame) || frame < 0 || frame >= def.durationInFrames) {
      throw new Error(`${name} timeline.${stage} 프레임이 범위를 벗어났습니다.`);
    }
    if (frame < previous) {
      throw new Error(`${name} timeline 프레임은 선언 순서대로 증가해야 합니다.`);
    }
    previous = frame;
  }
};

const assertSimulation = (name, def) => {
  if (!/^[A-Za-z0-9_-]+$/.test(name)) {
    throw new Error(`잘못된 Simulation ID: ${name}`);
  }
  if (!def || !def.component) {
    throw new Error(`${name} simulation 등록에 component가 없습니다.`);
  }
  if (def.height !== undefined && (!Number.isFinite(def.height) || def.height < 240)) {
    throw new Error(`${name} simulation height는 240 이상의 숫자여야 합니다.`);
  }
  const stages = def.stages ?? [];
  if (!Array.isArray(stages) || new Set(stages).size !== stages.length) {
    throw new Error(`${name} simulation stages는 중복 없는 배열이어야 합니다.`);
  }
  for (const stage of stages) {
    if (!VISUAL_ID.test(stage)) {
      throw new Error(`${name}의 잘못된 simulation stage-id: ${stage}`);
    }
  }
};

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

const syncedFrame = ({def, localSeconds, cueDuration, stages}) => {
  const lastFrame = def.durationInFrames - 1;
  const duration = Math.max(0.001, Number(cueDuration) || 0.001);
  const anchors = [{time: 0, frame: 0}];
  const timeline = def.timeline ?? {};
  for (const stage of stages ?? []) {
    const frame = timeline[stage.id];
    if (!Number.isFinite(frame) || !Number.isFinite(stage.offset)) continue;
    anchors.push({time: clamp(stage.offset, 0, duration), frame});
  }
  anchors.push({time: duration, frame: lastFrame});
  anchors.sort((a, b) => a.time - b.time || a.frame - b.frame);

  const deduped = [];
  for (const anchor of anchors) {
    const previous = deduped[deduped.length - 1];
    if (previous && Math.abs(previous.time - anchor.time) < 0.0005) {
      previous.frame = Math.max(previous.frame, anchor.frame);
    } else {
      deduped.push({...anchor});
    }
  }

  const time = clamp(Number(localSeconds) || 0, 0, duration);
  for (let index = 1; index < deduped.length; index++) {
    const left = deduped[index - 1];
    const right = deduped[index];
    if (time <= right.time) {
      const span = Math.max(0.001, right.time - left.time);
      const progress = clamp((time - left.time) / span, 0, 1);
      return Math.round(left.frame + (right.frame - left.frame) * progress);
    }
  }
  return lastFrame;
};

const activeStage = ({def, localSeconds, stages}) => {
  const allowed = def.stages?.length ? new Set(def.stages) : null;
  let current = null;
  for (const stage of [...(stages ?? [])].sort((a, b) => a.offset - b.offset)) {
    if (!VISUAL_ID.test(stage.id) || !Number.isFinite(stage.offset)) continue;
    if (allowed && !allowed.has(stage.id)) continue;
    if (stage.offset <= localSeconds + 0.02) current = stage.id;
  }
  return current;
};

export function register(compositions) {
  for (const [name, def] of Object.entries(compositions)) {
    assertComposition(name, def);
  }

  window.LearnAnim = {
    definitions: compositions,
    mount(el, name) {
      const def = compositions[name];
      if (!def) return null;
      const holder = {ref: null};
      createRoot(el).render(
        React.createElement(Player, {
          ref: (ref) => { holder.ref = ref; },
          component: def.component,
          durationInFrames: def.durationInFrames,
          fps: def.fps,
          compositionWidth: def.width,
          compositionHeight: def.height,
          style: {width: '100%'},
          initialFrame: 0,
          controls: true,
          loop: false,
          clickToPlay: true,
          doubleClickToFullscreen: true,
          spaceKeyToPlayOrPause: false,
          acknowledgeRemotionLicense: true,
        }),
      );
      return {
        play() { holder.ref?.play(); },
        pause() { holder.ref?.pause(); },
        seekTo(frame) { holder.ref?.seekTo(clamp(Math.round(frame), 0, def.durationInFrames - 1)); },
        sync(localSeconds, cueDuration, stages) {
          if (!holder.ref) return;
          const frame = syncedFrame({def, localSeconds, cueDuration, stages});
          if (holder.ref.isPlaying()) holder.ref.pause();
          if (holder.ref.getCurrentFrame() !== frame) holder.ref.seekTo(frame);
        },
        restart() {
          if (holder.ref) {
            holder.ref.seekTo(0);
            holder.ref.play();
          }
        },
        isPlaying() { return holder.ref ? holder.ref.isPlaying() : false; },
        getCurrentFrame() { return holder.ref ? holder.ref.getCurrentFrame() : 0; },
        durationInFrames: def.durationInFrames,
        fps: def.fps,
      };
    },
  };
}

export function registerSimulations(simulations) {
  for (const [name, def] of Object.entries(simulations)) {
    assertSimulation(name, def);
  }

  const definitions = {...(window.LearnSim?.definitions ?? {}), ...simulations};
  window.LearnSim = {
    definitions,
    mount(el, name) {
      const def = definitions[name];
      if (!def) return null;
      const root = createRoot(el);
      let resetToken = 0;
      let narration = {
        active: false,
        playing: false,
        localSeconds: 0,
        duration: 0,
        progress: 0,
        stage: null,
      };
      el.style.minHeight = `${def.height ?? 440}px`;

      const render = () => root.render(
        React.createElement(def.component, {
          key: resetToken,
          ...(def.defaultProps ?? {}),
          learnNarration: narration,
        }),
      );
      render();

      return {
        sync(localSeconds, cueDuration, stages, playing = false) {
          const duration = Math.max(0.001, Number(cueDuration) || 0.001);
          const local = clamp(Number(localSeconds) || 0, 0, duration);
          narration = {
            active: true,
            playing: Boolean(playing),
            localSeconds: local,
            duration,
            progress: local / duration,
            stage: activeStage({def, localSeconds: local, stages}),
          };
          render();
        },
        setNarrationActive(active, playing = false) {
          narration = {...narration, active: Boolean(active), playing: Boolean(playing)};
          render();
        },
        reset() {
          resetToken += 1;
          render();
        },
        unmount() { root.unmount(); },
      };
    },
  };
}
