
const virtual = 0x003fe00000

const offset = virtual & 0xFFF;
const l1_index = (virtual >> 12) & 0x1FF;
const l2_index = (virtual >> 21) & 0x1FF;
const l3_index = (virtual >> 30) & 0x1FF;
const l4_index = (virtual >> 39) & 0x1FF;

console.log(`${l4_index.toString(16)}-${l3_index.toString(16)}-${l2_index.toString(16)}-${l1_index.toString(16)}-${offset.toString(16)}`);

for (let i = 0; i < 256; i+= 1) {
  console.log(`GLOBAL_IDT.kernelISR(${i}, isr${i});`)
}

for (let i = 0; i < 256; i+= 1) {
  if (i < 30) {
    console.log(`fn isr${i}(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(${i}, frame, error_code); }`)
  } else {
    console.log(`fn isr${i}(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(${i}, frame, null); }`)
  }
}
