import { Composition } from "remotion";
import { Comparison } from "./Comparison";

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition
        id="Comparison"
        component={Comparison}
        durationInFrames={22 * 30}
        fps={30}
        width={1080}
        height={1920}
      />
    </>
  );
};
