// @ts-expect-error bun test runner types are not installed
import { describe, expect, test } from "bun:test";
import { addPin, clearPins, farPinWarning, normalizePins, pinEntries, pinLabel, questionPinKey, removePin, replaceFormPins, type MapPins } from "./site-map-pins";
import { buildSiteMap } from "../components/builder/useSiteMapSave";
import { buildInitialState, buildPageContent, formToPage, type IntakeForm, type PageBuilderData } from "../components/builder/builder-data";

const p = { lat: 25.761712345, lng: -80.191812345 };
describe("site map pin contract", () => {
  test("allows nine GT pins and no tenth pin or gt1", () => {
    let pins: MapPins = {};
    for (let n = 0; n < 10; n++) pins = addPin(pins, "gt", { ...p, lat: p.lat + n / 100 });
    expect(Object.keys(pins)).toEqual(["gt", "gt2", "gt3", "gt4", "gt5", "gt6", "gt7", "gt8", "gt9"]);
    expect(pinEntries(pins)).toHaveLength(9);
  });
  test("allows three truck pins and no truck4", () => {
    let pins: MapPins = {};
    for (let n = 0; n < 4; n++) pins = addPin(pins, "truck", p);
    expect(Object.keys(pins)).toEqual(["truck", "truck2", "truck3"]);
  });
  test("removing a middle GT compacts only GTs in order", () => {
    const third = { lat: 26, lng: -80 };
    expect(removePin({ gt: p, gt2: { lat: 27, lng: -80 }, gt3: third, truck: p }, "gt2")).toEqual({ gt: p, gt2: third, truck: p });
    expect(removePin({ gt: p, gt2: third, truck: p }, "gt")).toEqual({ gt: third, truck: p });
  });
  test("clear G and clear T remove all pins of only their kind", () => {
    expect(clearPins({ gt: p, gt2: p, truck: p, truck2: p }, "gt")).toEqual({ truck: p, truck2: p });
    expect(clearPins({ gt: p, gt2: p, truck: p, truck2: p }, "truck")).toEqual({ gt: p, gt2: p });
  });
  test("rejects unknown keys and rounds saved coordinates to six decimals", () => {
    expect(normalizePins({ gt1: p, gt10: p, truck4: p, gt2: p })).toEqual({ gt: p });
    expect(buildSiteMap({ gt: p, gt2: p, truck3: p }, []).pins).toEqual({ gt: { lat: 25.761712, lng: -80.191812 }, gt2: { lat: 25.761712, lng: -80.191812 }, truck: { lat: 25.761712, lng: -80.191812 } });
  });
  test("form keys map all nine traps and truck parking without gt1", () => {
    expect(questionPinKey("site_map.gt_location")).toBe("gt");
    for (let n = 2; n <= 9; n++) expect(questionPinKey(`grease_trap.t${n}.location`)).toBe(`gt${n}`);
    expect(questionPinKey("site_map.truck_parking")).toBe("truck");
    expect(questionPinKey("grease_trap.t10.location")).toBeNull();
    expect(pinLabel("gt")).toBe("GT1");
    expect(pinLabel("gt9")).toBe("GT9");
    expect(pinLabel("truck")).toBe("T1");
    expect(pinLabel("truck3")).toBe("T3");
  });
  test("form replacement replaces its entire kind without changing the other", () => {
    const next = { lat: 26, lng: -80 };
    expect(replaceFormPins({ gt: p, gt2: p, gt3: p, truck: p, truck2: p }, { gt: next, gt2: next })).toEqual({ gt: next, gt2: next, truck: p, truck2: p });
    expect(replaceFormPins({ gt: p, gt2: p, truck: p, truck2: p }, { truck: next })).toEqual({ gt: p, gt2: p, truck: next });
  });
  test("far warning counts additional pins and preserves single first-pin wording", () => {
    const far = { lat: 26.8, lng: -80.2 };
    expect(farPinWarning(p.lat, p.lng, { gt: far })?.startsWith("The GT Location pin is about")).toBe(true);
    expect(farPinWarning(p.lat, p.lng, { truck: far })?.startsWith("The Truck Parking pin is about")).toBe(true);
    expect(farPinWarning(p.lat, p.lng, { gt: p, gt2: far, truck2: far })?.startsWith("Some pins are about")).toBe(true);
  });
  test("form import and stored version/browser-draft loader keep every pin", () => {
    const form = { answers: Object.fromEntries([["site_map.gt_location", p], ...Array.from({ length: 8 }, (_, n) => [`grease_trap.t${n + 2}.location`, p]), ["site_map.truck_parking", p]]), photos: [] } as unknown as IntakeForm;
    expect(pinEntries(formToPage(form).pins)).toHaveLength(10);
    const pins = { ...formToPage(form).pins, truck2: p, truck3: p };
    const pb = { property: { lat: p.lat, lng: p.lng }, pending: { version: 4, content: { site_map: { pins, arrows: [] } } } } as unknown as PageBuilderData;
    const state = buildInitialState(pb, []).state;
    expect(pinEntries(state.mapPins)).toHaveLength(12);
    expect(Object.keys(buildPageContent(state).site_map?.pins ?? {})).toHaveLength(12);
    expect(buildInitialState({ ...pb, pending: null, live: null }, []).state.mapPins).toEqual({});
  });
});