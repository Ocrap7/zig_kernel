
const virtual = 0x003fe00000

const offset = virtual & 0xFFF;
const l1_index = (virtual >> 12) & 0x1FF;
const l2_index = (virtual >> 21) & 0x1FF;
const l3_index = (virtual >> 30) & 0x1FF;
const l4_index = (virtual >> 39) & 0x1FF;

console.log(`${l4_index.toString(16)}-${l3_index.toString(16)}-${l2_index.toString(16)}-${l1_index.toString(16)}-${offset.toString(16)}`);
