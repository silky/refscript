/*@ foo ::  ([#Mutable]{ x: [#Mutable] { v: number | v > 10 }; y: string + number }) => void */ 
function foo(o):void { 
    o.x = 20;
}