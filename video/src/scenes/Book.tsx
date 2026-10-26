// The order book, drawn to scale. A sell wall rises, then the camera pushes down to a sliver of
// bids, then a second bid bar (Plumb) grows beside it. Heights are proportional to the real
// amounts in props, read from chain.
import React from 'react';
import {AbsoluteFill} from 'remotion';
import {useScene} from '../lib/scene';
import {useLayout} from '../lib/layout';
import {EASE, tween, drift, ms} from '../lib/motion';
import {Backdrop} from '../components/Stage';
import {Counter, Words} from '../components/Type';

type Props = {
  ask: number; // MUSD offered
  bid: number; // USD bid
  plumb: number; // USD Plumb adds
  askLabel: string;
  bidLabel: string;
  plumbLabel: string;
  kicker?: string;
};

export const Book: React.FC<Props> = ({ask, bid, plumb, askLabel, bidLabel, plumbLabel, kicker}) => {
  const {f, ev, fps, brand, fg, bg, muted} = useScene();
  const L = useLayout();
  const W = L.w;
  const H = L.h;
  const base = H * 0.82; // floor line
  const maxH = H * 0.42;
  const unit = maxH / ask;
  const minBar = 4;

  const wallT = tween(f, ev('wall'), ev('wall') + ms(fps, 2400), 0, 1, EASE.premium);
  const bidT = tween(f, ev('bids'), ev('bids') + ms(fps, 500), 0, 1, EASE.enter);
  const plumbT = tween(f, ev('plumb'), ev('plumb') + ms(fps, 1100), 0, 1, EASE.premium);

  // Camera: wide on the wall, then push toward the bid side, then ease back for the payoff.
  const push = tween(f, ev('bids') - ms(fps, 200), ev('bids') + ms(fps, 1300), 0, 1, EASE.camera);
  const back = tween(f, ev('plumb') - ms(fps, 300), ev('plumb') + ms(fps, 900), 0, 1, EASE.camera);
  const zoom = 1 + 0.16 * push - 0.16 * back + 0.02 * (f / fps) / 10;
  const focusX = W * 0.36;
  const focusY = base - 40;
  const camX = (W / 2 - focusX) * (push - back * 0.85) * 0.5;
  const camY = (H / 2 - focusY) * (push - back * 0.85) * 0.25;

  const barW = W * 0.11;
  const wallX = W * 0.6;
  const bidX = W * 0.24;
  const plumbX = W * 0.41;
  const wallH = Math.max(minBar, ask * unit * wallT);
  // Bids first appear at true scale (a sliver), then magnify 40x with a visible note.
  const mag = 1 + 39 * tween(f, ev('mag'), ev('mag') + ms(fps, 900), 0, 1, EASE.premium);
  const bidH = Math.max(minBar, bid * unit * mag) * bidT;
  const plumbH = plumb * unit * mag * plumbT;

  const sell = '#FF8A1F';
  const buy = '#3DDC97';

  const label = (x: number, y: number, text: string, start: number, color: string, big = false) => (
    <div style={{position: 'absolute', left: x, top: y, transform: 'translate(-50%, -100%)', textAlign: 'center', whiteSpace: 'nowrap',
      fontFamily: brand.fontDisplay, fontWeight: 700, fontSize: big ? 64 : 44, letterSpacing: '-0.03em', color}}>
      <Words f={f} text={text} start={start} gap={60} />
    </div>
  );

  return (
    <AbsoluteFill>
      <Backdrop color={bg} glow={sell} glowAt={[0.6, 0.35]} glowOpacity={0.18 * wallT} glowSize={0.5} />
      {kicker ? (
        <div style={{position: 'absolute', top: L.safe.top, left: 0, right: 0, textAlign: 'center', fontFamily: brand.fontMono,
          fontSize: 26, letterSpacing: '0.18em', textTransform: 'uppercase', color: muted, opacity: tween(f, ev('bids') - ms(fps, 300), ev('bids'), 1, 0, EASE.exit)}}>
          {kicker}
        </div>
      ) : null}
      <AbsoluteFill style={{transform: `translate(${camX}px, ${camY + drift(f, 'book', 3, 400)}px) scale(${zoom})`, transformOrigin: `${focusX}px ${focusY}px`}}>
        {/* floor */}
        <div style={{position: 'absolute', left: W * 0.14, right: W * 0.14, top: base, height: 2, background: 'rgba(255,255,255,0.18)'}} />
        {/* sell wall */}
        <div style={{position: 'absolute', left: wallX - barW, top: base - wallH, width: barW * 2, height: wallH, borderRadius: 10,
          background: `linear-gradient(180deg, ${sell}, rgba(255,138,31,0.55))`}} />
        {label(wallX, base - wallH - 24, askLabel, ev('wall') + ms(fps, 500), fg, true)}
        <div style={{position: 'absolute', left: wallX, top: base - wallH - 24, transform: 'translate(-50%, -190%)', fontFamily: brand.fontDisplay,
          fontWeight: 760, fontSize: 96, letterSpacing: '-0.05em', color: sell, opacity: wallT}}>
          <Counter f={f} from={0} to={ask / 1e6} f0={ev('wall')} f1={ev('wall') + ms(fps, 2400)} decimals={1} suffix="M" />
        </div>
        {/* existing bids */}
        <div style={{position: 'absolute', left: bidX - barW / 2, top: base - bidH, width: barW, height: bidH, borderRadius: 3, background: buy, opacity: bidT}} />
        {label(bidX, base - bidH - 18, bidLabel, ev('bids') + ms(fps, 150), buy)}
        {/* Plumb */}
        <div style={{position: 'absolute', left: plumbX - barW / 2, top: base - plumbH, width: barW, height: plumbH, borderRadius: 6,
          background: `linear-gradient(180deg, #A6FFD6, ${buy})`, boxShadow: plumbT > 0 ? `0 0 ${40 * plumbT}px rgba(61,220,151,0.35)` : 'none'}} />
        {plumbT > 0 ? label(plumbX, base - plumbH - 20, plumbLabel, ev('plumb') + ms(fps, 300), fg, true) : null}
        <div style={{position: 'absolute', left: (bidX + plumbX) / 2, top: base + 24, transform: 'translateX(-50%)', fontFamily: brand.fontMono,
          fontSize: 22, letterSpacing: '0.08em', color: muted, opacity: tween(f, ev('mag'), ev('mag') + ms(fps, 400), 0, 1, EASE.enter), whiteSpace: 'nowrap'}}>
          BIDS DRAWN 40× TALLER
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
