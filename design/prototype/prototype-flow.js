/* Historical inspection prototypes remain connected and clearly labelled. */
(() => {
 const P=Prototype,{ $, $$, text, link, match, go, modal, status, copy, download }=P;
 const notice=document.createElement('nav');notice.className='proto-context';notice.innerHTML='旧版检查流程参考 <a href="tools.html">打开当前工具工作台 →</a>';document.body.prepend(notice);
 P.nav('.nav .item',{Workspace:'workspace.html',Objects:'objects.html',Diff:'diff.html',Unresolved:'unresolved.html',Patch:'patch.html'});
 $$('.nav .item').filter(x=>/ECUs|Communication/.test(text(x))).forEach(el=>link(el,()=>modal(text(el),'此分类属于旧版设计范围；当前原型未包含独立页面。',[],()=>go('tools.html'),'打开当前工作台')));
 P.nav('.sidebar .foot .st',{Settings:'settings.html'});
 const settings=$('.sidebar .foot');if(settings)link(settings,()=>go('settings.html'));
 match('button,.btn,.fixbtn,.go',/^Open in Objects|^Copy path|^Copy paths|^⌖ Trace|^Review findings/,b=>{if(/Copy/.test(text(b)))copy(text($('.finding .p'))||'/Vehicle/SwCs/SpeedSensor/CalibrationIn');else go(/findings|Trace/.test(text(b))?'unresolved.html':'objects.html')});
 match('button,.btn',/^Export/,()=>download('autarx-sample-findings.json',JSON.stringify({prototype:true,unresolved:[{source:'/Vehicle/SwCs/SpeedSensor/CalibrationIn',target:'IF_Calibration'}]},null,2)));
 match('button',/^Find/,()=>{const input=$('input')||$('.searchbox');const query=input?.value||text(input);$$('.objrow,tbody tr').forEach(row=>row.hidden=!!query&&!text(row).toLowerCase().includes(query.toLowerCase()));status('已筛选当前示例对象')});
 match('button',/^Compare/,()=>status('示例对比完成 · 现有结果为静态参考，不读取工程文件'));
 match('button',/^⇄$/,()=>{$$('.pick').reverse().forEach((el,i,arr)=>{if(i===0&&arr[1]){let s=el.innerHTML;el.innerHTML=arr[1].innerHTML;arr[1].innerHTML=s}});status('示例对比方向已交换')});
 match('button',/^⟳ Re-/,()=>status('示例索引检查完成 · 1 个未解析引用，未运行供应商工具'));
 match('button',/^Open Delivery/,()=>modal('Open sample delivery','仅打开随原型提供的示例，不读取本地工程。',[{label:'工程',name:'delivery',options:['OemDelivery']}],()=>status('已打开 OemDelivery 示例'),'Open'));
 match('button',/^Edit ops/,()=>modal('Patch sample','只编辑原型中的操作示例。',[{label:'操作',name:'ops',type:'textarea',value:'[{"op":"set","path":"/Vehicle","value":"sample"}]'}],d=>{try{const v=JSON.parse(d.ops);if(!Array.isArray(v))throw Error();status('示例 JSON 已验证，未应用到工程')}catch{status('请输入有效的 JSON 数组');return false}},'Validate'));
 const backdrop=$('.backdrop');if(backdrop)backdrop.hidden=true;
 match('button',/^Apply…/,()=>{if(backdrop)backdrop.hidden=false});
 match('button',/^Cancel/,()=>{if(backdrop)backdrop.hidden=true});
 match('button',/^Apply patch$/,()=>{if(backdrop)backdrop.hidden=true;status('示例 Patch 已确认 · 原型未修改工程文件')});
 match('button,.btn',/^About Autarx/,()=>modal('Autarx','工程能力工作台。当前页面为旧版设计参考，请从侧栏顶部链接进入当前方案。'));
 match('.btn',/^Relay validate/,()=>go('tools.html'));
 match('.btn',/^Rescan/,()=>status('示例状态保持 not found · 未扫描本机'));
 match('.btn',/^Check now/,()=>status('更新检查入口演示 · 未联网'));
 match('.btn',/^Reveal/,()=>modal('审计日志样例','原型未写入审计日志，也不打开本机文件。'));
 P.choices('.seg');
 document.addEventListener('keydown',e=>{if((e.metaKey||e.ctrlKey)&&e.key===','){e.preventDefault();go('settings.html')}if(e.key==='Escape'&&backdrop)backdrop.hidden=true});
})();
