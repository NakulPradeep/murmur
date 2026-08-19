import { Composition } from "remotion";
import { Comparison, TOTAL_SECONDS } from "./Comparison";

const FPS = 30;

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition
        id="Comparison"
        component={Comparison}
        durationInFrames={Math.round(TOTAL_SECONDS * FPS)}
        fps={FPS}
        width={1080}
        height={1920}
      />
    </>
  );
};
