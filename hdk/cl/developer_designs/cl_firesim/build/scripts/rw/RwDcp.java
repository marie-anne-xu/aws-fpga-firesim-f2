// Route an OOC-placed RM in the black-boxed RP of the base's firesim_top cell DCP; write the routed RM cell DCP.
//   RwDcp <fst.dcp> <fst.edf> <rm.dcp> <rm.edf> <rp> <CRs> <out_rm.dcp> <tpl.dcp> <tpl.edf> <routes.txt> <pblock>
import com.xilinx.rapidwright.design.*;
import com.xilinx.rapidwright.device.*;
import com.xilinx.rapidwright.edif.*;
import com.xilinx.rapidwright.rwroute.*;
import java.nio.file.*;
import java.util.*;
import java.util.function.Predicate;

public class RwDcp {
    // BFS-added PIPs: locked, so the extract keeps them explicitly.
    static final Set<PIP> MAZE_PIPS = new HashSet<>();
    static final Set<SitePinInst> MAZE_PINS = new HashSet<>();

    public static void main(String[] a) throws Exception {
        String rp = a[4];
        Set<String> crs = new HashSet<>(Arrays.asList(a[5].split(",")));
        Design fst = Design.readCheckpoint(a[0], a[1]);
        Device dev = fst.getDevice();
        // write_checkpoint -cell drops firesim_top's routing: re-apply the RP-region routes as locked PIPs.
        injectRoutes(fst, a[9]);

        Design rm = Design.readCheckpoint(a[2], a[3]);
        Set<SiteInst> rmSis = new HashSet<>(rm.getSiteInsts());
        for (Net n : rm.getNets()) n.setPIPs(new ArrayList<>());
        DesignTools.populateBlackBox(fst, rp, rm, true);
        fst.getNetlist().resetParentNetMap();
        DesignTools.makePhysNetNamesConsistent(fst);
        DesignTools.createMissingSitePinInsts(fst);

        // Partition pins at the base's PPLOC nodes (from the base's RP cell DCP).
        Design tpl = Design.readCheckpoint(a[7], a[8]);
        Map<String, Node> ppNode = new HashMap<>();
        List<PartitionPin> wirePPs = new ArrayList<>();
        for (PartitionPin pp : tpl.getPartitionPins()) {
            try {
                ppNode.put(pp.getTerminalName(), Node.getNode(pp.getNode().toString(), dev));
            } catch (Exception e) {
                wirePPs.add(pp); // clock partpin: site-pin wire, not a node
            }
        }
        for (Map.Entry<String, Node> e : ppNode.entrySet()) {
            EDIFHierPortInst hpi = fst.getNetlist().getHierPortInstFromName(rp + "/" + e.getKey());
            if (hpi != null) fst.createPartitionPin(hpi, e.getValue());
        }

        // Vivado ties unused FF SRST/CKEN and fractured-LUT A6 inputs to VCC; RapidWright has no pins for them.
        String[][] ctrl = {{"SRST1", "ABCD", "FF,FF2"}, {"SRST2", "EFGH", "FF,FF2"}, {"CKEN1", "ABCD", "FF"},
                {"CKEN2", "ABCD", "FF2"}, {"CKEN3", "EFGH", "FF"}, {"CKEN4", "EFGH", "FF2"}};
        for (SiteInst si : rmSis) {
            if (!si.getSiteName().startsWith("SLICE")) continue;
            for (String[] g : ctrl) {
                if (si.getSitePinInst(g[0]) != null) continue;
                boolean use = false;
                for (char c : g[1].toCharArray()) for (String suf : g[2].split(",")) if (si.getCell(c + suf) != null) use = true;
                if (use) fst.getVccNet().createPin(g[0], si);
            }
            for (char c : "ABCDEFGH".toCharArray())
                if (si.getCell(c + "5LUT") != null && si.getCell(c + "6LUT") != null && si.getSitePinInst(c + "6") == null)
                    fst.getVccNet().createPin(c + "6", si);
        }

        Set<Net> cand = new LinkedHashSet<>();
        for (SiteInst si : rmSis) for (SitePinInst sp : si.getSitePinInsts()) if (sp.getNet() != null) cand.add(sp.getNet());

        // Dual-output-LUT static source: locked route starts at <L>MUX, not <L>_O; re-point, BFS its RM sinks from the PPLOC.
        Set<Net> srcFixed = new HashSet<>();
        for (PartitionPin pp : fst.getPartitionPins()) {
            Net n = fst.getNetFromPartitionPin(pp);
            SitePinInst src = n == null ? null : n.getSource();
            if (src == null || rmSis.contains(src.getSiteInst())) continue;
            Map<Node, Node> prev = new HashMap<>();
            Set<Node> starts = new HashSet<>();
            for (PIP p : n.getPIPs()) { prev.put(p.getEndNode(), p.getStartNode()); starts.add(p.getStartNode()); }
            Node x = pp.getNode();
            for (int hops = 0; prev.containsKey(x) && hops < 10000; hops++) x = prev.get(x);
            Node sn = src.getConnectedNode();
            if (x.equals(sn) || x.getSitePin() == null || !x.getSitePin().getSite().equals(src.getSite())) continue;
            SitePinInst np = src.getSiteInst().getSitePinInst(x.getSitePin().getPinName());
            if (np == null) np = n.createPin(x.getSitePin().getPinName(), src.getSiteInst());
            if (np.equals(n.getAlternateSource())) n.setAlternateSource(null);
            n.setSource(np);
            if (starts.contains(sn)) n.setAlternateSource(src);
            else try { n.removePin(src); } catch (RuntimeException e) { }
            srcFixed.add(n);
        }
        mazeFromPP(fst, srcFixed, rmSis, crs);
        holdDetour(fst, rmSis, crs);

        List<SitePinInst> pins = new ArrayList<>();
        for (Net n : cand) {
            DesignTools.updatePinsIsRouted(n);
            SitePinInst src = n.getSource();
            boolean rmDriven = !n.isStaticNet() && src != null && rmSis.contains(src.getSiteInst());
            for (SitePinInst sp : n.getPins())
                if (!sp.isOutPin() && !sp.isRouted() && !MAZE_PINS.contains(sp) && (rmDriven || rmSis.contains(sp.getSiteInst())))
                    pins.add(sp);
        }
        // GND->VCC LUT-input inversion edits LUT INITs, which the RM-only extract would lose.
        String[] rargs = {"--fixBoundingBox", "--useUTurnNodes", "--nonTimingDriven", "--noInvertGndToVccForLutInputs",
                "--pblock", a[10]};
        PartialDFXRouter.routeDesignWithUserDefinedArguments(fst, rargs, pins, false);

        Set<Node> ppNodes = new HashSet<>();
        for (PartitionPin pp : fst.getPartitionPins()) ppNodes.add(pp.getNode());
        for (Net n : cand) if (!n.isStaticNet() && !NetTools.isGlobalClock(n)) dedupDrivers(n, ppNodes);

        // Extract: RM placement + new PIPs of the matching firesim_top nets.
        Design out = Design.readCheckpoint(a[2], a[3]);
        for (Net n : out.getNets()) {
            Net fn;
            if (n.isStaticNet()) fn = fst.getStaticNet(n.getType());
            else {
                EDIFHierNet hn = fst.getNetlist().getHierNetFromName(rp + "/" + n.getName());
                fn = hn == null ? null : fst.getNet(fst.getNetlist().getParentNet(hn).getHierarchicalNetName());
            }
            List<PIP> np = new ArrayList<>();
            if (fn != null) for (PIP p : fn.getPIPs()) {
                if (p.isPIPFixed() && !MAZE_PIPS.contains(p)) continue;
                if (n.isStaticNet()) {
                    ClockRegion cr = p.getTile().getClockRegion();
                    if (cr == null || !crs.contains(cr.getName())) continue;
                }
                np.add(p);
            }
            n.setPIPs(np);
        }
        // Port partition pins = the base's, incl. the clock's site-pin wire.
        Set<String> wireTerms = new HashSet<>();
        for (PartitionPin pp : wirePPs) wireTerms.add(pp.getTerminalName());
        for (PartitionPin pp : new ArrayList<>(out.getPartitionPins()))
            if (wireTerms.contains(pp.getTerminalName())) out.removePartitionPin(pp);
        for (PartitionPin pp : wirePPs) {
            Tile tt = out.getDevice().getTile(pp.getTileName());
            PartitionPin np = new PartitionPin(tt, tt.getWireIndex(pp.getWireName()), pp.isFixed(), pp.isWireFixed());
            np.b(pp.getTerminalName());
            out.addPartitionPin(np);
        }
        for (PartitionPin pp : out.getPartitionPins()) {
            Node w = ppNode.get(pp.getTerminalName());
            if (w != null) pp.setNode(w);
        }
        out.writeCheckpoint(a[6]);
    }

    // "<net> <pip> ..." per line; nets outside firesim_top become pinless blockers.
    static void injectRoutes(Design d, String file) throws Exception {
        String pre = "WRAPPER/CL/firesim_top/";
        int blk = 0;
        for (String l : Files.readAllLines(Paths.get(file))) {
            String[] f = l.trim().split("\\s+");
            if (f.length < 2) continue;
            Net n = f[0].startsWith(pre) ? d.getNet(f[0].substring(pre.length())) : null;
            if (n == null) { n = new Net("rwf_route_blocker_" + blk++); d.addNet(n); }
            Set<PIP> ps = new LinkedHashSet<>(n.getPIPs());
            for (int i = 1; i < f.length; i++) {
                PIP p = d.getDevice().getPIP(f[i]);
                p.setIsPIPFixed(true);
                ps.add(p);
            }
            n.setPIPs(new ArrayList<>(ps));
        }
    }

    static Set<Node> usedNodes(Design d) {
        Set<Node> used = new HashSet<>();
        for (Net m : d.getNets()) for (PIP p : m.getPIPs()) { used.add(p.getStartNode()); used.add(p.getEndNode()); }
        for (SiteInst si : d.getSiteInsts()) for (SitePinInst sp : si.getSitePinInsts()) used.add(sp.getConnectedNode());
        return used;
    }

    static void lock(Net n, List<PIP> ps, Set<Node> used) {
        for (PIP p : ps) {
            p.setIsPIPFixed(true);
            n.addPIP(p);
            used.add(p.getEndNode());
            MAZE_PIPS.add(p);
        }
    }

    // BFS over free nodes in the RP clock regions to 'to', or (to == null) the first node matching 'goal'.
    static List<PIP> bfs(Node from, Node to, Predicate<Node> goal, Set<Node> used, Set<Node> own, Set<String> crs, Node[] last) {
        Map<Node, Node> par = new HashMap<>();
        Deque<Node> q = new ArrayDeque<>();
        q.add(from);
        par.put(from, from);
        for (int popped = 0; !q.isEmpty() && popped < 3000000; popped++) {
            Node x = q.poll();
            if (to != null ? x.equals(to) : (!x.equals(from) && goal.test(x))) {
                if (last != null) last[0] = x;
                List<Node> path = new ArrayList<>();
                for (Node y = x; !y.equals(from); y = par.get(y)) path.add(y);
                path.add(from);
                Collections.reverse(path);
                List<PIP> ps = new ArrayList<>();
                for (int k = 0; k + 1 < path.size(); k++) {
                    PIP p = PIP.getArbitraryPIP(path.get(k), path.get(k + 1));
                    if (p == null) return null;
                    ps.add(p);
                }
                return ps;
            }
            for (Node y : x.getAllDownhillNodes()) {
                if (par.containsKey(y)) continue;
                if (to == null || !y.equals(to)) {
                    if ((used.contains(y) && !own.contains(y)) || y.isTied() || y.getSitePin() != null) continue;
                    ClockRegion cr = y.getTile().getClockRegion();
                    if (cr == null || !crs.contains(cr.getName())) continue;
                }
                par.put(y, x);
                q.add(y);
            }
        }
        return null;
    }

    static void mazeFromPP(Design fst, Set<Net> nets, Set<SiteInst> rmSis, Set<String> crs) {
        if (nets.isEmpty()) return;
        Map<Net, Node> ppOfNet = new HashMap<>();
        for (PartitionPin pp : fst.getPartitionPins()) {
            Net n = fst.getNetFromPartitionPin(pp);
            if (n != null) ppOfNet.put(n, pp.getNode());
        }
        Set<Node> used = usedNodes(fst);
        for (Net n : nets) {
            Node pp = ppOfNet.get(n);
            DesignTools.updatePinsIsRouted(n);
            Set<Node> own = new HashSet<>();
            for (PIP p : n.getPIPs()) { own.add(p.getStartNode()); own.add(p.getEndNode()); }
            for (SitePinInst sp : n.getPins()) {
                if (sp.isOutPin() || sp.isRouted() || !rmSis.contains(sp.getSiteInst())) continue;
                List<PIP> ps = bfs(pp, sp.getConnectedNode(), null, used, own, crs, null);
                if (ps == null) continue;
                lock(n, ps, used);
                for (PIP p : ps) own.add(p.getEndNode());
                MAZE_PINS.add(sp);
            }
        }
    }

    // RWRoute is not timing-driven (FF->LUTRAM hold misses): detour LUTRAM inputs via a node >= 6 INT tiles away.
    static final int HOLD_DETOUR = 6;

    static void holdDetour(Design fst, Set<SiteInst> rmSis, Set<String> crs) {
        Set<Node> used = usedNodes(fst);
        for (SiteInst si : rmSis) {
            boolean ram = false;
            for (Cell c : si.getCells()) if (c.getType() != null && c.getType().startsWith("RAM")) ram = true;
            if (!ram) continue;
            for (SitePinInst sp : si.getSitePinInsts()) {
                Net n = sp.getNet();
                if (sp.isOutPin() || n == null || n.isStaticNet() || NetTools.isGlobalClock(n) || sp.isRouted()) continue;
                if (sp.getName().startsWith("CLK")) continue;
                SitePinInst src = n.getSource();
                if (src == null || !rmSis.contains(src.getSiteInst())) continue;
                boolean toRam = false;
                for (BELPin bp : si.getSiteWirePins(sp.getName())) {
                    Cell c = si.getCell(bp.getBEL());
                    if (c != null && c.getType() != null && c.getType().startsWith("RAM")) toRam = true;
                }
                if (!toRam) continue;
                Node sink = sp.getConnectedNode();
                int sx = sink.getTile().getTileXCoordinate(), sy = sink.getTile().getTileYCoordinate();
                Set<Node> own = new HashSet<>();
                for (PIP p : n.getPIPs()) { own.add(p.getStartNode()); own.add(p.getEndNode()); }
                Node[] wp = new Node[1];
                Set<Node> bad = new HashSet<>();
                List<PIP> a1 = null, a2 = null;
                for (int tryN = 0; tryN < 12 && a2 == null; tryN++) {
                    a1 = bfs(src.getConnectedNode(), null, x -> !bad.contains(x)
                            && x.getTile().getTileTypeEnum() == TileTypeEnum.INT
                            && Math.abs(x.getTile().getTileXCoordinate() - sx) + Math.abs(x.getTile().getTileYCoordinate() - sy) >= HOLD_DETOUR
                            && (x.getIntentCode() == IntentCode.NODE_SINGLE || x.getIntentCode() == IntentCode.NODE_DOUBLE
                                || x.getIntentCode() == IntentCode.NODE_HQUAD || x.getIntentCode() == IntentCode.NODE_VQUAD),
                            used, own, crs, wp);
                    if (a1 == null) break;
                    Set<Node> own2 = new HashSet<>(own);
                    for (PIP p : a1) own2.add(p.getEndNode());
                    a2 = bfs(wp[0], sink, null, used, own2, crs, null);
                    if (a2 == null) bad.add(wp[0]);
                }
                if (a2 == null) continue;
                Set<PIP> have = new HashSet<>(n.getPIPs());
                List<PIP> add = new ArrayList<>();
                for (PIP p : a1) if (have.add(p)) add.add(p);
                for (PIP p : a2) if (have.add(p)) add.add(p);
                lock(n, add, used);
                MAZE_PINS.add(sp);
            }
        }
    }

    // BFS + RWRoute PIPs can drive a node twice: keep one per node (locked first), prune dead branches.
    static Node effStart(PIP p) { return p.isReversed() ? p.getEndNode() : p.getStartNode(); }
    static Node effEnd(PIP p) { return p.isReversed() ? p.getStartNode() : p.getEndNode(); }

    static void dedupDrivers(Net n, Set<Node> keepTerms) {
        if (n.getSource() == null || !n.hasPIPs()) return;
        Set<Node> endSeen = new HashSet<>();
        boolean dbl = false;
        for (PIP p : n.getPIPs()) if (!endSeen.add(effEnd(p))) { dbl = true; break; }
        if (!dbl) return;
        Map<Node, List<PIP>> byStart = new HashMap<>();
        for (PIP p : n.getPIPs()) byStart.computeIfAbsent(effStart(p), k -> new ArrayList<>()).add(p);
        Map<Node, PIP> chosen = new LinkedHashMap<>();
        Deque<Node> q = new ArrayDeque<>();
        Set<Node> seen = new HashSet<>();
        for (SitePinInst sp : n.getPins()) if (sp.isOutPin()) { q.add(sp.getConnectedNode()); seen.add(sp.getConnectedNode()); }
        while (!q.isEmpty()) {
            List<PIP> out = byStart.get(q.poll());
            if (out == null) continue;
            out.sort((u, v) -> Boolean.compare(!u.isPIPFixed(), !v.isPIPFixed()));
            for (PIP p : out) {
                Node e = effEnd(p);
                if (!seen.add(e)) continue;
                chosen.put(e, p);
                q.add(e);
            }
        }
        Set<Node> terms = new HashSet<>(keepTerms);
        for (SitePinInst sp : n.getPins()) if (!sp.isOutPin()) terms.add(sp.getConnectedNode());
        List<PIP> keep = new ArrayList<>(chosen.values());
        for (boolean changed = true; changed; ) {
            changed = false;
            Set<Node> starts = new HashSet<>();
            for (PIP p : keep) starts.add(effStart(p));
            List<PIP> nk = new ArrayList<>();
            for (PIP p : keep) if (starts.contains(effEnd(p)) || terms.contains(effEnd(p))) nk.add(p); else changed = true;
            keep = nk;
        }
        n.setPIPs(keep);
    }
}
