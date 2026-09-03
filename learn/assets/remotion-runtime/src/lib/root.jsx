import React from 'react';
import {Composition} from 'remotion';

export const LearnRoot = () => {
  const definitions = window.LearnAnim?.definitions ?? {};
  return (
    <>
      {Object.entries(definitions).map(([id, def]) => (
        <Composition
          key={id}
          id={id}
          component={def.component}
          durationInFrames={def.durationInFrames}
          fps={def.fps}
          width={def.width}
          height={def.height}
          defaultProps={def.defaultProps ?? {}}
          calculateMetadata={def.calculateMetadata}
        />
      ))}
    </>
  );
};
