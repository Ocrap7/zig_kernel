
const virtual = 0x7FBFC8000000n

const offset = virtual & 0xFFFn;
const l1_index = (virtual >> 12n) & 0x1FFn;
const l2_index = (virtual >> 21n) & 0x1FFn;
const l3_index = (virtual >> 30n) & 0x1FFn;
const l4_index = (virtual >> 39n) & 0x1FFn;

console.log(l4_index, l3_index, l2_index, l1_index)
// console.log((virtual >> 1).toString(2),`${Number(l4_index).toString(16)}-${Number(l3_index).toString(16)}-${Number(l2_index).toString(16)}-${Number(l1_index).toString(16)}-${Number(offset).toString(16)}`);

const errorCodes = [8, 10, 11, 12, 13, 14, 17, 30]

// for (let i = 0; i < 256; i+= 1) {
//   if (errorCodes.includes(i)) {
//     console.log(`GLOBAL_IDT.kernelErrorISR(${i}, isr${i});`)
//   } else {
//     console.log(`GLOBAL_IDT.kernelISR(${i}, isr${i});`)
//   }
// }

for (let i = 0; i < 256; i += 1) {
    if (errorCodes.includes(i)) {
        console.log(`fn isr${i}() callconv(.Naked) void { asm volatile ("cli; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (${i})); }`)
    } else {
        console.log(`fn isr${i}() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (${i})); }`)
    }
}
