export const INSPECTION_METHODS=[
 ['visual','육안검사'],['dimension','치수측정'],['functional','기능검사'],['other','기타']
];
export const inspectionLabel=code=>INSPECTION_METHODS.find(([value])=>value===code)?.[1]||'미기록';
