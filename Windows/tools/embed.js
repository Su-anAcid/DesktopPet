// 把 pet.dat 转成 C 数组头文件，这样即使没有 windres 也能编出单文件 exe
const fs = require('fs');
const data = fs.readFileSync(process.argv[2] || 'assets/pet.dat');
const lines = [];
lines.push('// 由 tools/embed.js 自动生成，请勿手改');
lines.push('#pragma once');
lines.push('static const unsigned char kPetData[] = {');
for (let i = 0; i < data.length; i += 24) {
  const chunk = [];
  for (let j = i; j < Math.min(i + 24, data.length); j++) chunk.push('0x' + data[j].toString(16).padStart(2, '0'));
  lines.push('  ' + chunk.join(',') + ',');
}
lines.push('};');
lines.push(`static const unsigned long kPetDataLen = ${data.length}UL;`);
fs.writeFileSync(process.argv[3] || 'src/pet_data.h', lines.join('\n') + '\n');
console.log('wrote', process.argv[3] || 'src/pet_data.h', data.length, 'bytes');
