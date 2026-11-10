import { useState } from "react";
import { COLOR_HEX, type Annotation } from "@/lib/access-pdf-types";

/**
 * Image at its natural aspect ratio (object-contain, never cropped) with the
 * marks drawn over the image box. Mark coordinates are fractions 0..1 of the
 * photo, so x=0.5, y=0.5 is always the centre of the photo.
 */
export function MarkedImage({
  src,
  alt,
  marks = [],
  className,
  imgClassName,
  onError,
  loading,
}: {
  src: string;
  alt: string;
  marks?: Annotation[];
  className?: string;
  imgClassName?: string;
  onError?: () => void;
  loading?: "lazy" | "eager";
}) {
  const [ratio, setRatio] = useState(1); // height / width
  const W = 1000;
  const H = W * ratio;
  const u = W / 1000; // stroke/size unit

  return (
    <span className={`relative inline-block max-w-full align-top ${className ?? ""}`}>
      <img
        src={src}
        alt={alt}
        onError={onError}
        loading={loading}
        onLoad={(e) => {
          const i = e.currentTarget;
          if (i.naturalWidth && i.naturalHeight) setRatio(i.naturalHeight / i.naturalWidth);
        }}
        className={`block h-auto max-w-full object-contain ${imgClassName ?? ""}`}
      />
      {marks.length > 0 && (
        <svg
          className="pointer-events-none absolute inset-0 h-full w-full"
          viewBox={`0 0 ${W} ${H}`}
          preserveAspectRatio="none"
          aria-hidden="true"
        >
          <defs>
            {Object.entries(COLOR_HEX).map(([name, hex]) => (
              <marker
                key={name}
                id={`mi-arrow-${name}`}
                viewBox="0 0 10 10"
                refX="8"
                refY="5"
                markerWidth="6"
                markerHeight="6"
                orient="auto-start-reverse"
              >
                <path d="M 0 0 L 10 5 L 0 10 z" fill={hex} />
              </marker>
            ))}
          </defs>
          {marks.map((a) => {
            const hex = COLOR_HEX[a.color] ?? COLOR_HEX.red;
            if (a.kind === "circle") {
              return (
                <g key={a.id}>
                  <circle cx={a.x * W} cy={a.y * H} r={26 * u} fill={hex} stroke="white" strokeWidth={3 * u} />
                  <text
                    x={a.x * W}
                    y={a.y * H}
                    textAnchor="middle"
                    dominantBaseline="central"
                    fontSize={28 * u}
                    fontWeight="bold"
                    fill={a.color === "yellow" || a.color === "white" ? "#000" : "#fff"}
                  >
                    {a.number}
                  </text>
                </g>
              );
            }
            if (a.kind === "arrow") {
              return (
                <line
                  key={a.id}
                  x1={a.x1 * W}
                  y1={a.y1 * H}
                  x2={a.x2 * W}
                  y2={a.y2 * H}
                  stroke={hex}
                  strokeWidth={6 * u}
                  markerEnd={`url(#mi-arrow-${a.color})`}
                />
              );
            }
            if (a.kind === "ring") {
              return (
                <ellipse
                  key={a.id}
                  cx={(a.x + a.w / 2) * W}
                  cy={(a.y + a.h / 2) * H}
                  rx={(a.w / 2) * W}
                  ry={(a.h / 2) * H}
                  fill="none"
                  stroke={hex}
                  strokeWidth={6 * u}
                />
              );
            }
            if (a.kind === "rect") {
              return (
                <rect
                  key={a.id}
                  x={a.x * W}
                  y={a.y * H}
                  width={a.w * W}
                  height={a.h * H}
                  fill="none"
                  stroke={hex}
                  strokeWidth={6 * u}
                />
              );
            }
            return (
              <g key={a.id}>
                <rect
                  x={a.x * W - 4}
                  y={a.y * H - 22}
                  width={a.text.length * 13 + 8}
                  height="28"
                  fill="rgba(0,0,0,0.55)"
                  rx="3"
                />
                <text x={a.x * W} y={a.y * H} fontSize="22" fontWeight="bold" fill={hex}>
                  {a.text}
                </text>
              </g>
            );
          })}
        </svg>
      )}
    </span>
  );
}
