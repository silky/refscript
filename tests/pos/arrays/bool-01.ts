
let emp: MArray<number> = [];

//Needed to infer mutability
emp.push(1);
emp.pop();

assert(!(emp === null));
