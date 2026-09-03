import {staticFile} from 'remotion';

const REMOTE_OR_EMBEDDED = /^(?:https?:|data:|blob:)/i;

export const learnAsset = (path) => {
  if (typeof path !== 'string' || path.length === 0) {
    throw new TypeError('learnAsset()에는 비어 있지 않은 문자열 경로가 필요합니다.');
  }
  if (REMOTE_OR_EMBEDDED.test(path)) return path;
  if (path.startsWith('/') || path.startsWith('.') || path.startsWith('public/')) {
    throw new TypeError(`learnAsset()에는 public 기준 상대 경로를 넘기세요: ${path}`);
  }

  const encoded = path.split('/').map(encodeURIComponent).join('/');
  if (typeof window !== 'undefined' && window.location?.protocol === 'file:') {
    return `assets/${encoded}`;
  }
  return staticFile(path);
};
