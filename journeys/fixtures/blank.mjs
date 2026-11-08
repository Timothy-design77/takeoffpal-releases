// The in-repo synthetic fixtures, made byte-for-byte the same every time:
// - the blank calibrated project: one 36 x 24 in electrical sheet (a border, a title block, a few room walls, no
//   devices), made into a project through the real API and calibrated at 1/4" = 1'-0" (18 pt per ft), as the Scale
//   tool saves a two-point scale;
// - the scope set: that plan (E1.1) and a legend and notes sheet (E0.01) whose notes say what the contractor does,
//   never picked and with no scope card.
import fs from 'node:fs';
import path from 'node:path';

export const SHEET = {width: 2592, height: 1728};       // points: 36 x 24 in
export const PT_PER_FT = 18;                             // 1/4" = 1'-0"
export const CALIBRATION = {points: [[100, 100], [280, 100]], known_length: '10', unit: 'FT'};

const text = (x, y, size, value) => `BT /F1 ${size} Tf ${x} ${y} Td (${value.replace(/[()\\]/g, '\\$&')}) Tj ET`;
const WALLS = [[216, 216, 2160, 216], [2160, 216, 2160, 1404], [2160, 1404, 216, 1404], [216, 1404, 216, 216],
  [1188, 216, 1188, 1404], [216, 810, 1188, 810], [1674, 216, 1674, 1404]];
const BORDER = ['0.2 w 0 0 0 RG', '36 36 2520 1656 re S'];

/** A PDF of one page per content stream, all the sheet's size, in Helvetica. */
function pdfOf(contents) {
  const pages = contents.length, font = 3 + 2 * pages;
  const objects = ['<< /Type /Catalog /Pages 2 0 R >>',
    `<< /Type /Pages /Kids [${contents.map((_, i) => `${3 + 2 * i} 0 R`).join(' ')}] /Count ${pages} >>`,
    ...contents.flatMap((content, i) => [
      `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${SHEET.width} ${SHEET.height}] /Resources << /Font << /F1 ${font} 0 R >> >> /Contents ${4 + 2 * i} 0 R >>`,
      `<< /Length ${Buffer.byteLength(content, 'latin1')} >>\nstream\n${content}\nendstream`]),
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'];
  let body = '%PDF-1.4\n';
  const offsets = [];
  objects.forEach((object, index) => { offsets.push(Buffer.byteLength(body, 'latin1')); body += `${index + 1} 0 obj\n${object}\nendobj\n`; });
  const xref = Buffer.byteLength(body, 'latin1');
  body += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n` + offsets.map(o => String(o).padStart(10, '0') + ' 00000 n \n').join('');
  body += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(body, 'latin1');
}

const PLAN = [...BORDER, '2 w', ...WALLS.map(([x1, y1, x2, y2]) => `${x1} ${SHEET.height - y1} m ${x2} ${SHEET.height - y2} l S`),
  '0.5 w 2232 36 324 180 re S',
  text(2250, 170, 18, 'JOURNEY BLANK'), text(2250, 140, 14, 'ELECTRICAL PLAN'), text(2250, 110, 14, 'E1.1'),
  text(2250, 80, 10, 'SCALE: 1/4" = 1\'-0"'), text(600, 1500, 12, 'OFFICE'), text(1400, 1500, 12, 'OPEN AREA'),
  text(1800, 1500, 12, 'STORAGE')].join('\n');

export function blankPdf() { return pdfOf([PLAN]); }

/** The scope notes the E0.01 sheet prints (a reader drafts the card from them). */
export const SCOPE_NOTES = ['GENERAL NOTE 1: PROVIDE ALL ELECTRICAL WORK PER DIVISION 26.',
  'DATA CABLING BY OTHERS. EC TO PROVIDE BOXES, CONDUIT AND PULL STRING.', 'FIRE ALARM SYSTEM BY OWNER VENDOR.',
  'EQUIPMENT FURNISHED BY OTHERS: EC TO CONNECT ONLY.'];

/** A titled sheet: its title block (title, then the sheet number large, bottom right), room walls or notes. */
function sheet(number, title, {walls = true, notes = []} = {}) {
  return [...BORDER, '2 w', ...(walls ? WALLS.map(([x1, y1, x2, y2]) => `${x1} ${SHEET.height - y1} m ${x2} ${SHEET.height - y2} l S`) : []),
    '0.5 w 2232 36 324 180 re S', text(2250, 140, 14, title), text(2250, 90, 28, number),
    ...(notes.length ? [text(200, 1500, 20, 'GENERAL NOTES'), ...notes.map((note, index) => text(200, 1450 - 40 * index, 16, note))] : []),
  ].join('\n');
}

export function scopeSetPdf() {
  return pdfOf([PLAN, sheet('E0.01', 'ELECTRICAL LEGEND AND NOTES', {walls: false, notes: SCOPE_NOTES})]);
}

/** The mixed set, in this order: an E power plan, the architect's floor plan it covers, the architect's reflected
 * ceiling plan no E plan covers, a mechanical plan and the legend and notes. */
export const MIXED = [['E1.01', 'FIRST FLOOR POWER PLAN'], ['A2.01', 'FLOOR PLAN'], ['A5.01', 'REFLECTED CEILING PLAN'],
  ['M2.01', 'MECHANICAL PLAN'], ['E0.01', 'ELECTRICAL LEGEND AND NOTES']];

export function mixedSetPdf() {
  return pdfOf(MIXED.map(([number, title]) => sheet(number, title, number === 'E0.01' ? {walls: false, notes: SCOPE_NOTES} : {})));
}

/** A long electrical set, E1.01 up: enough sheets that the Sheets window scrolls. */
export function longSetPdf(count) {
  return pdfOf(Array.from({length: count}, (_, index) => sheet(`E1.${String(index + 1).padStart(2, '0')}`, `POWER PLAN AREA ${index + 1}`)));
}

export function createMixedSetProject(api, directory, name = 'Journey mixed set') {
  return createProject(api, directory, {name, pdf: mixedSetPdf(), filename: 'mixed-set.pdf', calibrate: [0, 1, 2]});
}

/** A project made from `pdf` in `directory` through the running backend's API, its `calibrate` pages scaled. */
export async function createProject(api, directory, {name, pdf, filename, calibrate = [0]}) {
  fs.mkdirSync(directory, {recursive: true});
  await api.post('/api/v1/project/create', {name, directory: path.resolve(directory)});
  let info = await api.session();
  const generation = info.generation ?? (await api.project()).generation;  // an older build's session has none
  const query = new URLSearchParams({filename, revision_id: 'rev-1', expected_generation: String(generation),
    command_id: crypto.randomUUID(), project_session_id: info.project_session_id});
  const added = await api.call('/api/v1/source?' + query, {method: 'POST', body: pdf, headers: {'content-type': 'application/pdf'}});
  for (const index of calibrate) {
    await api.command('calibrate_page', {page_id: added.page_ids[index], ...CALIBRATION, reason: 'Two-point, 10 FT'});
  }
  info = await api.session();
  return {projectPath: info.project_path, pageIds: added.page_ids, pageId: added.page_ids[0], generation: info.generation ?? (await api.project()).generation};
}

/** The blank calibrated project in `directory`. */
export function createBlankProject(api, directory, name = 'Journey blank') {
  return createProject(api, directory, {name, pdf: blankPdf(), filename: 'blank-plan.pdf'});
}

/** The scope set (never picked, no scope card) in `directory`, its plan calibrated. */
export function createScopeSetProject(api, directory, name = 'Journey scope set') {
  return createProject(api, directory, {name, pdf: scopeSetPdf(), filename: 'scope-set.pdf'});
}

/** Place a mark as the Add tool saves one (a 12 pt box at `at`); `words` are its item type as the plan names it
 * (the kind by default), `attributes` join its record role. */
export function mark(api, pageId, id, kind, category, at, {attributes = {}, words = kind, label = null} = {}) {
  return api.command('add_entity', {entity_id: id, entity_type: kind, classification: words, label,
    electrical_category: category, page_id: pageId, quantity: '1', unit: 'EA',
    geometry: {type: 'bbox', bbox: [at[0] - 6, at[1] - 6, at[0] + 6, at[1] + 6]}, attributes: {record_role: 'physical', ...attributes}});
}
