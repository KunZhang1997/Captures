import { Composition } from "remotion";
import { CaptureDemo } from "./CaptureDemo";

export const Root: React.FC = () => {
  return (
    <Composition
      id="CaptureDemo"
      component={CaptureDemo}
      durationInFrames={192}
      fps={24}
      width={800}
      height={500}
    />
  );
};
