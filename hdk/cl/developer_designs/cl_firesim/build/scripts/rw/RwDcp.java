// RapidWright helper for the F2 nested-DFX prefetcher child flow (RapidWright 2025.2.2).
// 2026-10-15 (rw_a/rw_a2): the full base and WRAPPER/CL cannot be exported readable (EDIF 20-92 AWS top,
// Designutils 20-2284 sh_ddr helpers), so 'stitch'/'route' below never ran on the real design.
// 2026-10-19/20 (rwf_1..8): WRAPPER/CL/firesim_top IS readable -> 'fst' = the working firesim_top-level flow
// (see main_pr_rwfst_base.tcl / main_pr_rm_rwfst.tcl).
// Single-file Java (launch via run_rw.sh). Subcommands:
//   roundtrip <in.dcp> <in.edf|-> <out.dcp>
//       time readCheckpoint + writeCheckpoint, print design stats (A).
//   stitch <base.dcp> <base.edf|-> <rm.dcp> <rm.edf|-> <rp_hier> <pplocs.txt> <out.dcp> [route=1]
//       black-box the RP in the base (static GND/VCC and static-side boundary routing kept),
//       populate it with the placed+routed RM cell checkpoint, partially route what is left
//       (boundary sinks), write DCP (B/C).
//   fst <fst.dcp> <fst.edf> <rm.dcp> <rm.edf|-> <rp_rel> <pplocs.txt> <blockers.txt|-> <CRs> <out_rm.dcp>
//       [strip=1] [<pp_template.dcp|-> <pp_template.edf|->] [<routes.txt|->] [<pblock|->]
//       routes.txt ("<vivado net> <pip> ..." per line, dumped from the base after black_box + lock): Vivado's
//       write_checkpoint -cell drops nearly all routing of a big hierarchical cell (fst rdb 161 KB, RW sees 0 PIPs;
//       same for WRAPPER/CL in rw_a2), so the routing of every net using the RP region (+ GND/VCC there) is
//       re-applied here as fixed PIPs (unknown net -> pinless blocker). pblock (e.g.
//       CLOCKREGION_X1Y0:CLOCKREGION_X2Y0) confines RWRoute to the region whose routing is known.
//       2026-10-19 firesim_top-level child flow (rwf_*): <fst.dcp> = Vivado write_checkpoint -cell
//       WRAPPER/CL/firesim_top of the nested base with the RP black-boxed and static routing locked
//       (+ its write_edif). Populates the black box with the RM (placement kept; routing stripped if strip=1),
//       blocks the nodes of nets outside firesim_top (blockers.txt: "<net> <pip> ..." per line, from Vivado),
//       routes RM-internal + RP-boundary pins with PartialDFXRouter (RM side of static-sourced nets starts at
//       the base PPLOC partition pin; static-sinked nets end at it), checks every new PIP lies in the RP
//       clock regions (CRs, e.g. X1Y0,X2Y0), and writes only the routed RP as an RM cell DCP (placement +
//       new PIPs + port partition pins) for Vivado read_checkpoint -cell.
//   route <in.dcp> <in.edf|-> <out.dcp> [timing=0]
//       RWRoute partial routing of all unrouted pins, existing routing preserved (D).
import com.xilinx.rapidwright.design.*;
import com.xilinx.rapidwright.device.*;
import com.xilinx.rapidwright.edif.*;
import com.xilinx.rapidwright.rwroute.*;
import java.nio.file.*;
import java.util.*;

public class RwDcp {
    static long T0 = System.nanoTime();
    static long tPrev = T0;

    static void t(String k) {
        long now = System.nanoTime();
        System.out.printf("RW_TIME %s %.1f%n", k, (now - tPrev) / 1e9);
        tPrev = now;
    }

    static Design read(String dcp, String edf) {
        tPrev = System.nanoTime();
        Design d = edf.equals("-") ? Design.readCheckpoint(dcp) : Design.readCheckpoint(dcp, edf);
        t("read " + Paths.get(dcp).getFileName());
        return d;
    }

    static void stats(String tag, Design d) {
        long pips = 0;
        int routed = 0;
        for (Net n : d.getNets()) {
            pips += n.getPIPs().size();
            if (n.hasPIPs()) routed++;
        }
        EDIFNetlist nl = d.getNetlist();
        System.out.printf("RW_STAT %s part=%s top=%s cells=%d siteinsts=%d nets=%d routedNets=%d pips=%d "
                        + "encrypted=%d ooc=%b adv=%b%n",
                tag, d.getPartName(), nl.getTopCell().getName(), d.getCells().size(), d.getSiteInsts().size(),
                d.getNets().size(), routed, pips, nl.getEncryptedCells().size(), d.isDesignOutOfContext(),
                d.isAdvancedFlow());
        for (String e : nl.getEncryptedCells()) System.out.println("RW_ENC " + tag + " " + e);
        for (ConstraintGroup g : ConstraintGroup.values()) {
            List<String> x = d.getXDCConstraints(g);
            System.out.println("RW_XDC " + tag + " " + g + " lines=" + (x == null ? 0 : x.size()));
            if (x != null) {
                int i = 0;
                for (String l : x) {
                    if (l.contains("HD.") || l.contains("pblock") || l.contains("PARTPIN") || l.contains("RECONFIG")
                            || l.contains("CONTAINER") || l.contains("LOCK")) {
                        if (i++ < 40) System.out.println("RW_XDCL " + tag + " " + g + ": " + l);
                    }
                }
            }
        }
    }

    public static void main(String[] a) throws Exception {
        switch (a[0]) {
            case "roundtrip": {
                Design d = read(a[1], a[2]);
                stats("in", d);
                t("stats");
                d.writeCheckpoint(a[3]);
                t("write " + Paths.get(a[3]).getFileName());
                break;
            }
            case "stitch":
                stitch(a);
                break;
            case "fst":
                fst(a);
                break;
            case "route": {
                Design d = read(a[1], a[2]);
                boolean timing = a.length > 4 && a[4].equals("1");
                List<SitePinInst> pins = PartialRouter.getUnroutedPins(d);
                System.out.println("RW_ROUTE unrouted pins=" + pins.size());
                t("prep");
                if (timing) PartialRouter.routeDesignPartialTimingDriven(d, pins, false);
                else PartialRouter.routeDesignPartialNonTimingDriven(d, pins, false);
                t("rwroute");
                System.out.println("RW_ROUTE still unrouted=" + PartialRouter.getUnroutedPins(d).size());
                d.writeCheckpoint(a[3]);
                t("write");
                break;
            }
            default:
                throw new IllegalArgumentException(a[0]);
        }
        System.out.printf("RW_TIME total %.1f%n", (System.nanoTime() - T0) / 1e9);
    }

    // BFS maze route of unrouted sinks of static-driven boundary nets from the net's PPLOC node, avoiding every
    // used node, inside the RP clock regions (no congestion negotiation; for the few connections PartialDFXRouter
    // cannot handle: dual-output-LUT sources, rwf_3 local).
    static final Set<PIP> MAZE_PIPS = new HashSet<>();
    static final Set<SitePinInst> MAZE_PINS = new HashSet<>();

    static final Map<Net, List<PIP>> MAZE_BY_NET = new HashMap<>();

    // BFS path from -> to over unused nodes (own net's nodes allowed) inside the RP clock regions.
    static List<PIP> bfs(Node from, Node to, Set<Node> used, Set<Node> own, Set<String> crs, int[] popped) {
        return bfs(from, to, null, used, own, crs, popped, null);
    }

    // goal: exact node 'to', or (to == null) the first non-site-pin node satisfying 'goal'. 'last' returns the end node.
    static List<PIP> bfs(Node from, Node to, java.util.function.Predicate<Node> goal, Set<Node> used, Set<Node> own,
                         Set<String> crs, int[] popped, Node[] last) {
        Map<Node, Node> par = new HashMap<>();
        Deque<Node> q = new ArrayDeque<>();
        q.add(from);
        par.put(from, from);
        popped[0] = 0;
        while (!q.isEmpty() && popped[0] < 3000000) {
            Node x = q.poll();
            popped[0]++;
            if (to != null ? x.equals(to) : (!x.equals(from) && goal.test(x))) {
                if (last != null) last[0] = x;
                List<Node> path = new ArrayList<>();
                for (Node y = x; !y.equals(from); y = par.get(y)) path.add(y);
                path.add(from);
                Collections.reverse(path);
                // explicit start->end PIP per hop (RouterHelper.getPIPsFromNodes expects RWRoute's sink-first order)
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
                    if ((used.contains(y) && !own.contains(y)) || y.isTied()) continue;
                    ClockRegion cr = y.getTile().getClockRegion();
                    if (cr == null || !crs.contains(cr.getName())) continue;
                    if (y.getSitePin() != null) continue; // never through other site pins
                }
                par.put(y, x);
                q.add(y);
            }
        }
        return null;
    }

    // BFS maze routing (no congestion negotiation) for the few boundary connections PartialDFXRouter cannot do:
    //  - static-driven nets whose source pin had to be re-pointed (dual-output LUT): PPLOC -> each RM sink;
    //  - RM-driven nets whose RP pin has no base PPLOC but whose locked static route starts at a single dangling
    //    node inside the RP region (AMPM io_request_bits_address[3]): RM source -> that node.
    // PIPs are locked (kept by PartialDFXRouter as preserved routing), and re-added after it (MAZE_BY_NET) since
    // RWRoute rewrites the PIPs of nets it touched from its own connection state.
    static void maze(Design fst, Collection<Net> cand, Set<Net> only, Set<SiteInst> rmSis, Set<String> crs, String tag) {
        Map<Net, Node> ppOfNet = new HashMap<>();
        for (PartitionPin pp : fst.getPartitionPins()) {
            Net n = fst.getNetFromPartitionPin(pp);
            if (n != null) ppOfNet.put(n, pp.getNode());
        }
        Set<Node> used = null;
        int ok = 0, todo = 0;
        int[] popped = new int[1];
        for (Net n : cand) {
            if (n.isStaticNet() || NetTools.isGlobalClock(n)) continue;
            if (only != null && !only.contains(n)) continue;
            DesignTools.updatePinsIsRouted(n);
            SitePinInst src = n.getSource();
            boolean rmDriven = src != null && rmSis.contains(src.getSiteInst());
            List<SitePinInst> left = new ArrayList<>();
            for (SitePinInst sp : n.getPins())
                if (!sp.isOutPin() && !sp.isRouted() && (rmDriven || rmSis.contains(sp.getSiteInst()))) left.add(sp);
            if (left.isEmpty()) continue;
            Node pp = ppOfNet.get(n);
            List<Object[]> jobs = new ArrayList<>(); // {from, to, label}
            if (!rmDriven && pp != null) {
                for (SitePinInst sp : left) jobs.add(new Object[]{pp, sp.getConnectedNode(), sp.toString()});
            } else if (rmDriven && pp != null) {
                jobs.add(new Object[]{src.getConnectedNode(), pp, "to PPLOC " + pp});
            } else if (rmDriven && pp == null) {
                Set<Node> ends = new HashSet<>(), roots = new LinkedHashSet<>();
                for (PIP p : n.getPIPs()) if (p.isPIPFixed()) ends.add(p.getEndNode());
                for (PIP p : n.getPIPs()) if (p.isPIPFixed() && !ends.contains(p.getStartNode())) roots.add(p.getStartNode());
                if (roots.size() == 1) jobs.add(new Object[]{src.getConnectedNode(), roots.iterator().next(), "root " + roots});
                else System.out.println("RW_MAZE skip " + n.getName() + " RM-driven, no PPLOC, locked roots=" + roots);
            } else {
                continue; // PartialDFXRouter's job (or retry later)
            }
            if (used == null) {
                used = new HashSet<>();
                for (Net m : fst.getNets()) for (PIP p : m.getPIPs()) { used.add(p.getStartNode()); used.add(p.getEndNode()); }
                for (SiteInst si : fst.getSiteInsts()) for (SitePinInst sp : si.getSitePinInsts()) used.add(sp.getConnectedNode());
            }
            Set<Node> own = new HashSet<>();
            for (PIP p : n.getPIPs()) { own.add(p.getStartNode()); own.add(p.getEndNode()); }
            for (Object[] jb : jobs) {
                todo++;
                List<PIP> ps = bfs((Node) jb[0], (Node) jb[1], used, own, crs, popped);
                if (ps == null) { System.out.println("RW_MAZE FAIL " + n.getName() + " " + jb[2] + " from=" + jb[0] + " popped=" + popped[0]); continue; }
                for (PIP p : ps) {
                    p.setIsPIPFixed(true);
                    n.addPIP(p);
                    used.add(p.getEndNode());
                    own.add(p.getEndNode());
                    MAZE_PIPS.add(p);
                    MAZE_BY_NET.computeIfAbsent(n, k -> new ArrayList<>()).add(p);
                }
                ok++;
                System.out.println("RW_MAZE ok " + n.getName() + " " + jb[2] + " pips=" + ps.size() + " popped=" + popped[0]);
            }
            DesignTools.updatePinsIsRouted(n);
            for (SitePinInst sp : left) if (sp.isRouted()) MAZE_PINS.add(sp);
        }
        System.out.println("RW_MAZE " + tag + " jobs=" + todo + " routed=" + ok + " mazePins=" + MAZE_PINS.size());
        t("maze pass " + tag);
    }

    // Hold: RapidWright routes non-timing-driven and minimal, and FF -> LUTRAM (RAMD32/RAMS32 I, WADR) connections
    // then miss hold by up to 45 ps (rwf_5/rwf_6 r3b: 39 paths, WHS=-0.045; Vivado's targeted route_design -nets
    // -delay did not fix them, only a full ~12 min route_design did). Pre-route every RM-internal connection into a
    // LUTRAM input with a detour through a node >= HOLD_DETOUR INT tiles away from the sink (~+0.1-0.2 ns).
    static int HOLD_DETOUR = Integer.parseInt(System.getenv().getOrDefault("RW_HOLD_DETOUR", "6"));

    static void holdDetour(Design fst, Set<SiteInst> rmSis, Set<String> crs) {
        if (HOLD_DETOUR <= 0) return;
        Set<Node> used = new HashSet<>();
        for (Net m : fst.getNets()) for (PIP p : m.getPIPs()) { used.add(p.getStartNode()); used.add(p.getEndNode()); }
        for (SiteInst si : fst.getSiteInsts()) for (SitePinInst sp : si.getSitePinInsts()) used.add(sp.getConnectedNode());
        int jobs = 0, ok = 0, fail = 0;
        int[] popped = new int[1];
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
                // only pins that feed a LUTRAM BEL
                boolean toRam = false;
                for (BELPin bp : sp.getSiteInst().getSiteWirePins(sp.getName())) {
                    Cell c = si.getCell(bp.getBEL());
                    if (c != null && c.getType() != null && c.getType().startsWith("RAM")) toRam = true;
                }
                if (!toRam) continue;
                jobs++;
                Node sink = sp.getConnectedNode();
                Tile st = sink.getTile();
                int sx = st.getTileXCoordinate(), sy = st.getTileYCoordinate();
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
                            used, own, crs, popped, wp);
                    if (a1 == null) break;
                    Set<Node> own2 = new HashSet<>(own);
                    for (PIP p : a1) own2.add(p.getEndNode());
                    a2 = bfs(wp[0], sink, null, used, own2, crs, popped, null);
                    if (a2 == null) bad.add(wp[0]);
                }
                if (a2 == null) { fail++; continue; }
                Set<PIP> have = new HashSet<>(n.getPIPs());
                for (List<PIP> ps : Arrays.asList(a1, a2)) for (PIP p : ps) {
                    if (!have.add(p)) continue;
                    p.setIsPIPFixed(true);
                    n.addPIP(p);
                    used.add(p.getEndNode());
                    MAZE_PIPS.add(p);
                    MAZE_BY_NET.computeIfAbsent(n, k -> new ArrayList<>()).add(p);
                }
                MAZE_PINS.add(sp);
                ok++;
            }
        }
        System.out.println("RW_HOLD detour (>= " + HOLD_DETOUR + " INT tiles) LUTRAM-input connections=" + jobs + " routed=" + ok + " failed=" + fail);
        t("hold detour");
    }

    // After restoreMaze a net can drive one node through two PIPs (RWRoute's tree for its other sinks + the BFS
    // path) -> Vivado "resource conflict"/antenna on the same net (local check of rwf_7's RP). Keep, per end node,
    // the PIP whose start is reachable from the source (BFS order), then prune branches that lead nowhere.
    static Node effStart(PIP p) { return p.isReversed() ? p.getEndNode() : p.getStartNode(); }
    static Node effEnd(PIP p) { return p.isReversed() ? p.getStartNode() : p.getEndNode(); }

    static int dedupDrivers(Net n, Set<Node> keepTerms) {
        SitePinInst src = n.getSource();
        if (src == null || !n.hasPIPs()) return 0;
        Set<Node> endSeen = new HashSet<>();
        boolean dbl = false;
        for (PIP p : n.getPIPs()) if (!endSeen.add(effEnd(p))) { dbl = true; break; }
        if (!dbl) return 0;
        Map<Node, List<PIP>> byStart = new HashMap<>();
        for (PIP p : n.getPIPs()) byStart.computeIfAbsent(effStart(p), k -> new ArrayList<>()).add(p);
        Map<Node, PIP> chosen = new LinkedHashMap<>();
        Deque<Node> q = new ArrayDeque<>();
        Set<Node> seen = new HashSet<>();
        for (SitePinInst sp : n.getPins()) if (sp.isOutPin()) { q.add(sp.getConnectedNode()); seen.add(sp.getConnectedNode()); }
        while (!q.isEmpty()) {
            Node x = q.poll();
            List<PIP> out = byStart.get(x);
            if (out == null) continue;
            out.sort((u, v) -> Boolean.compare(!u.isPIPFixed(), !v.isPIPFixed())); // locked / BFS PIPs first
            for (PIP p : out) {
                Node e = effEnd(p);
                if (seen.contains(e)) continue;
                chosen.put(e, p);
                seen.add(e);
                q.add(e);
            }
        }
        // prune branches that no longer lead to a sink pin / partition pin
        Set<Node> terms = new HashSet<>(keepTerms);
        for (SitePinInst sp : n.getPins()) if (!sp.isOutPin()) terms.add(sp.getConnectedNode());
        List<PIP> keep = new ArrayList<>(chosen.values());
        boolean changed = true;
        while (changed) {
            changed = false;
            Set<Node> starts = new HashSet<>();
            for (PIP p : keep) starts.add(effStart(p));
            List<PIP> nk = new ArrayList<>();
            for (PIP p : keep) {
                Node e = effEnd(p);
                if (starts.contains(e) || terms.contains(e)) nk.add(p); else changed = true;
            }
            keep = nk;
        }
        int before = n.getPIPs().size();
        n.setPIPs(keep);
        return before - keep.size();
    }

    static void restoreMaze() {
        int re = 0;
        for (Map.Entry<Net, List<PIP>> e : MAZE_BY_NET.entrySet()) {
            Set<PIP> have = new HashSet<>(e.getKey().getPIPs());
            for (PIP p : e.getValue()) if (have.add(p)) { e.getKey().addPIP(p); re++; }
            DesignTools.updatePinsIsRouted(e.getKey());
        }
        System.out.println("RW_MAZE restored pips=" + re + " on " + MAZE_BY_NET.size() + " nets");
    }

    // ---------------------------------------------------------------- fst (firesim_top-level swap)
    static String bareTerm(String full, String rpFull) {
        return full.substring(rpFull.length() + 1);
    }

    static void injectRoutes(Design d, String file) throws Exception {
        EDIFNetlist nl = d.getNetlist();
        String pre = "WRAPPER/CL/firesim_top/";
        int byName = 0, byParent = 0, stat = 0, blk = 0, bad = 0, lines = 0;
        long pips = 0;
        java.io.BufferedReader br = Files.newBufferedReader(Paths.get(file));
        String l;
        while ((l = br.readLine()) != null) {
            String[] f = l.trim().split("\\s+");
            if (f.length < 2) continue;
            lines++;
            String vn = f[0];
            Net n = null;
            if (vn.equals("__GND__")) { n = d.getGndNet(); stat++; }
            else if (vn.equals("__VCC__")) { n = d.getVccNet(); stat++; }
            else if (vn.startsWith(pre)) {
                String rel = vn.substring(pre.length());
                n = d.getNet(rel);
                if (n != null) byName++;
                else {
                    EDIFHierNet hn = nl.getHierNetFromName(rel);
                    if (hn != null) {
                        EDIFHierNet pn = nl.getParentNet(hn);
                        n = d.getNet(pn.getHierarchicalNetName());
                        if (n == null) n = d.createNet(pn);
                        byParent++;
                    }
                }
            }
            if (n == null) {
                n = new Net("rwf_route_blocker_" + blk++);
                d.addNet(n);
                if (blk <= 10) System.out.println("RW_INJECT blocker for " + vn);
            }
            Set<PIP> ps = new LinkedHashSet<>(n.getPIPs());
            for (int i = 1; i < f.length; i++) {
                PIP p = d.getDevice().getPIP(f[i]);
                if (p == null) { bad++; continue; }
                p.setIsPIPFixed(true);
                ps.add(p);
            }
            pips += ps.size() - n.getPIPs().size();
            n.setPIPs(new ArrayList<>(ps));
        }
        br.close();
        System.out.println("RW_INJECT lines=" + lines + " byName=" + byName + " byParent=" + byParent + " static=" + stat
                + " blockers=" + blk + " pips=" + pips + " unparsed=" + bad);
        t("inject routes");
    }

    static void fst(String[] a) throws Exception {
        String rp = a[5];
        boolean strip = a.length <= 10 || a[10].equals("1");
        Set<String> crs = new HashSet<>(Arrays.asList(a[8].split(",")));
        String tplDcp = a.length > 11 && !a[11].equals("-") ? a[11] : null;
        String routesF = a.length > 13 && !a[13].equals("-") ? a[13] : null;
        String pblock = a.length > 14 && !a[14].equals("-") ? a[14] : null;
        Design fst = read(a[1], a[2]);
        dev = fst.getDevice();
        // R1 stats
        long pips = 0, fixedPips = 0;
        int routedNets = 0;
        for (Net n : fst.getNets()) {
            for (PIP p : n.getPIPs()) {
                pips++;
                if (p.isPIPFixed()) fixedPips++;
            }
            if (n.hasPIPs()) routedNets++;
        }
        int placed = 0;
        for (Cell c : fst.getCells()) if (c.getSite() != null) placed++;
        System.out.printf("RW_R1 top=%s cells=%d placedCells=%d siteinsts=%d nets=%d routedNets=%d pips=%d fixedPips=%d "
                        + "encrypted=%d ooc=%b partitionPins=%d%n",
                fst.getNetlist().getTopCell().getName(), fst.getCells().size(), placed, fst.getSiteInsts().size(),
                fst.getNets().size(), routedNets, pips, fixedPips, fst.getNetlist().getEncryptedCells().size(),
                fst.isDesignOutOfContext(), fst.getPartitionPins().size());
        EDIFHierCellInst rpInst = fst.getNetlist().getHierCellInstFromName(rp);
        System.out.println("RW_R1 rp " + rp + " found=" + (rpInst != null)
                + (rpInst == null ? "" : " blackbox=" + rpInst.getInst().isBlackBox() + " type=" + rpInst.getCellName()));
        int shown = 0;
        for (PartitionPin pp : fst.getPartitionPins()) {
            if (shown++ < 5) System.out.println("RW_R1 pp " + pp.getInstanceName() + "/" + pp.getTerminalName() + " " + pp.getNode());
        }
        t("r1 stats");

        if (routesF != null) injectRoutes(fst, routesF);
        // Lock every existing PIP (static is locked in Vivado; make sure RW sees it as fixed).
        long nowFixed = 0;
        for (Net n : fst.getNets()) {
            for (PIP p : n.getPIPs()) {
                if (!p.isPIPFixed()) {
                    p.setIsPIPFixed(true);
                    nowFixed++;
                }
            }
        }
        System.out.println("RW_FST pips newly marked fixed=" + nowFixed);

        Design rm = read(a[3], a[4]);
        Set<SiteInst> rmSis = new HashSet<>(rm.getSiteInsts());
        long rmPips = 0;
        for (Net n : rm.getNets()) {
            rmPips += n.getPIPs().size();
            if (strip) n.setPIPs(new ArrayList<>());
        }
        System.out.println("RW_FST rm cells=" + rm.getCells().size() + " siteinsts=" + rmSis.size() + " pips=" + rmPips
                + (strip ? " (stripped)" : " (kept)"));
        DesignTools.populateBlackBox(fst, rp, rm, true);
        fst.getNetlist().resetParentNetMap();
        DesignTools.makePhysNetNamesConsistent(fst);
        DesignTools.createMissingSitePinInsts(fst);
        // Locked static PIPs injected on a boundary net's outside segment can stay on that alias after populate
        // (RM-driven io_request_bits_address[3], no base PPLOC): move them onto the physical (parent) net.
        int moved = 0;
        {
            EDIFHierCellInst rpI = fst.getNetlist().getHierCellInstFromName(rp);
            for (EDIFPortInst pi : rpI.getInst().getPortInsts()) {
                if (pi.getNet() == null) continue;
                EDIFHierNet hn = new EDIFHierNet(rpI.getParent(), pi.getNet());
                EDIFHierNet par = fst.getNetlist().getParentNet(hn);
                Net pn = par == null ? null : fst.getNet(par.getHierarchicalNetName());
                if (pn == null || pn.isStaticNet()) continue;
                for (EDIFHierNet al : fst.getNetlist().getNetAliases(hn)) {
                    Net an = fst.getNet(al.getHierarchicalNetName());
                    if (an == null || an == pn || !an.hasPIPs()) continue;
                    Set<PIP> u = new LinkedHashSet<>(pn.getPIPs());
                    u.addAll(an.getPIPs());
                    pn.setPIPs(new ArrayList<>(u));
                    System.out.println("RW_FST moved " + an.getPIPs().size() + " PIPs from alias " + an.getName() + " to " + pn.getName());
                    fst.removeNet(an);
                    moved++;
                }
            }
        }
        System.out.println("RW_FST alias nets merged=" + moved);
        if (System.getenv("RW_DEBUG_PORTS") != null) {
            EDIFHierCellInst rpI = fst.getNetlist().getHierCellInstFromName(rp);
            for (String pn : System.getenv("RW_DEBUG_PORTS").split(",")) {
                EDIFPortInst pi = rpI.getInst().getPortInst(pn);
                EDIFNet inner = pi == null ? null : rpI.getCellType().getInternalNet(pi);
                System.out.println("RW_DEBUG port " + pn + " outer=" + (pi == null ? null : pi.getNet()) + " inner=" + inner
                        + " idx=" + (pi == null ? -1 : pi.getIndex()) + " portWidth=" + (pi == null ? -1 : pi.getPort().getWidth()));
            }
        }
        if (System.getenv("RW_DEBUG_NET") != null) {
            for (String dn : System.getenv("RW_DEBUG_NET").split(",")) {
                Net x = fst.getNet(dn);
                System.out.println("RW_DEBUG net " + dn + " -> " + (x == null ? null : x.getName() + " pips=" + x.getPIPs().size() + " pins=" + x.getPins() + " src=" + x.getSource()));
                EDIFHierNet h = fst.getNetlist().getHierNetFromName(dn);
                if (h != null) {
                    EDIFHierNet pr = fst.getNetlist().getParentNet(h);
                    System.out.println("RW_DEBUG   parent=" + pr + " aliases=" + fst.getNetlist().getNetAliases(h));
                }
            }
        }
        t("populateBlackBox");

        // Partition pins at the base PPLOC nodes (instance pins of the RP), unless the DCP already carried them.
        int ppBefore = fst.getPartitionPins().size(), ppNew = 0;
        Map<String, Node> pplocOf = new HashMap<>();
        String rpFull = null;
        for (String l : Files.readAllLines(Paths.get(a[6]))) {
            String[] f = l.trim().split("\\s+");
            if (f.length < 2) continue;
            if (rpFull == null) rpFull = f[0].substring(0, f[0].lastIndexOf('/'));
            if (f.length != 2) continue; // clock: CLK_HDISTR pair, handled by the clock router
            Node nd = Node.getNode(f[1].replaceAll("[{}]", ""), dev);
            pplocOf.put(bareTerm(f[0], rpFull), nd);
        }
        Set<String> have = new HashSet<>();
        for (PartitionPin pp : fst.getPartitionPins()) have.add(pp.getTerminalName());
        for (Map.Entry<String, Node> e : pplocOf.entrySet()) {
            if (have.contains(e.getKey())) continue;
            EDIFHierPortInst hpi = fst.getNetlist().getHierPortInstFromName(rp + "/" + e.getKey());
            if (hpi == null || e.getValue() == null) {
                System.out.println("RW_WARN no hier port inst / node for " + e.getKey());
                continue;
            }
            fst.createPartitionPin(hpi, e.getValue());
            ppNew++;
        }
        System.out.println("RW_FST partition pins: carried=" + ppBefore + " created=" + ppNew);

        // Blockers: nodes of nets outside firesim_top (invisible here) -> pinless preserved dummy nets.
        Set<Node> staticNodes = new HashSet<>();
        for (Net sn : new Net[]{fst.getGndNet(), fst.getVccNet()})
            for (PIP p : sn.getPIPs()) { staticNodes.add(p.getStartNode()); staticNodes.add(p.getEndNode()); }
        int nBlk = 0, blkPips = 0, blkBad = 0, blkDup = 0;
        if (!a[7].equals("-")) {
            for (String l : Files.readAllLines(Paths.get(a[7]))) {
                String[] f = l.trim().split("\\s+");
                if (f.length < 2) continue;
                List<PIP> ps = new ArrayList<>();
                for (int i = 1; i < f.length; i++) {
                    PIP p = dev.getPIP(f[i]);
                    if (p == null) { blkBad++; continue; }
                    if (staticNodes.contains(p.getStartNode()) || staticNodes.contains(p.getEndNode())) { blkDup++; continue; }
                    p.setIsPIPFixed(true);
                    ps.add(p);
                }
                if (ps.isEmpty()) continue;
                Net bn = new Net("rwf_blocker_" + nBlk++);
                bn.setPIPs(ps);
                fst.addNet(bn);
                blkPips += ps.size();
            }
        }
        System.out.println("RW_FST blockers nets=" + nBlk + " pips=" + blkPips + " unparsed=" + blkBad + " onFstStatic=" + blkDup);

        // Vivado ties the unused CTRL inputs of every used FF group to VCC (VCC_WIRE->CTRL_W6/7 in the INT tile)
        // but RapidWright has no site pin for them; the merge then reports GLOBAL_LOGIC1 "unrouted nodes"
        // (rwf_4 r3b). Rule (exact on the in-context AMPM RM, 876 such PIPs): SRST1 if any A-D FF/FF2 is used,
        // SRST2 for E-H; CKEN1/2/3/4 if A-D FF / A-D FF2 / E-H FF / E-H FF2 is used -- and the pin carries no signal.
        int tied = 0;
        String[][] ctrl = {{"SRST1", "ABCD", "FF,FF2"}, {"SRST2", "EFGH", "FF,FF2"}, {"CKEN1", "ABCD", "FF"},
                {"CKEN2", "ABCD", "FF2"}, {"CKEN3", "EFGH", "FF"}, {"CKEN4", "EFGH", "FF2"}};
        for (SiteInst si : rmSis) {
            if (!si.getSiteName().startsWith("SLICE")) continue;
            for (String[] g : ctrl) {
                if (si.getSitePinInst(g[0]) != null) continue;
                boolean use = false;
                for (char c : g[1].toCharArray()) for (String suf : g[2].split(",")) if (si.getCell(c + suf) != null) use = true;
                if (!use) continue;
                fst.getVccNet().createPin(g[0], si);
                tied++;
            }
        }
        // Same for a fractured LUT (both 5LUT and 6LUT used): Vivado ties its A6..H6 input to VCC; RapidWright only
        // has that pin when the input DCP was routed (rwf_5 r3a, OOC-placed RM: GLOBAL_LOGIC1 unrouted IMUX nodes).
        int tied6 = 0;
        for (SiteInst si : rmSis) {
            if (!si.getSiteName().startsWith("SLICE")) continue;
            for (char c : "ABCDEFGH".toCharArray()) {
                if (si.getCell(c + "5LUT") == null || si.getCell(c + "6LUT") == null) continue;
                if (si.getSitePinInst(c + "6") != null) continue;
                fst.getVccNet().createPin(c + "6", si);
                tied6++;
            }
        }
        System.out.println("RW_FST VCC-tied unused FF control pins created=" + tied + ", fractured-LUT A6 pins created=" + tied6);

        // Pins to route: unrouted pins of nets that touch an RM site; for GND/VCC only the RM-site sinks.
        Set<Net> cand = new LinkedHashSet<>();
        for (SiteInst si : rmSis) {
            for (SitePinInst sp : si.getSitePinInsts()) if (sp.getNet() != null) cand.add(sp.getNet());
        }
        List<SitePinInst> pins = new ArrayList<>();
        int bnd = 0, clk = 0;
        for (Net n : cand) {
            DesignTools.updatePinsIsRouted(n);
            boolean st = n.isStaticNet();
            boolean outside = false;
            // Static sinks are routed only for RM-driven nets (RM pin -> base PPLOC, rest locked); for static-
            // driven nets (incl. the clock, GND/VCC) only RM-site sinks: the cell DCP carries no static routing, so
            // static sinks outside the injected region would otherwise all look unrouted (rwf_3: 80406 clock pins).
            SitePinInst src = n.getSource();
            boolean rmDriven = !st && src != null && rmSis.contains(src.getSiteInst());
            for (SitePinInst sp : n.getPins()) {
                boolean in = rmSis.contains(sp.getSiteInst());
                if (!in) outside = true;
                if (sp.isOutPin() || sp.isRouted() || MAZE_PINS.contains(sp)) continue;
                if (!in && !rmDriven) continue;
                pins.add(sp);
            }
            if (!st && outside) bnd++;
            if (NetTools.isGlobalClock(n)) clk++;
        }
        // Diagnose PP locked paths: walk each PP node back through its net's PIPs to the source.
        int ppOk = 0, ppBad = 0;
        Set<Net> srcFixed = new HashSet<>();
        for (PartitionPin pp : fst.getPartitionPins()) {
            Net n = fst.getNetFromPartitionPin(pp);
            if (n == null) { System.out.println("RW_PPDIAG nonet " + pp.getTerminalName()); ppBad++; continue; }
            Map<Node, Node> prev = new HashMap<>();
            Set<Node> starts = new HashSet<>();
            for (PIP p : n.getPIPs()) { prev.put(p.getEndNode(), p.getStartNode()); starts.add(p.getStartNode()); }
            Node x = pp.getNode();
            boolean inNet = prev.containsKey(x) || starts.contains(x);
            int hops = 0;
            while (prev.containsKey(x) && hops < 10000) { x = prev.get(x); hops++; }
            SitePinInst src = n.getSource();
            Node sn = src == null ? null : src.getConnectedNode();
            boolean rmSrc = src != null && rmSis.contains(src.getSiteInst());
            boolean ok = rmSrc || (sn != null && sn.equals(x));
            String fix = "";
            if (!ok && src != null && x.getSitePin() != null && x.getSitePin().getSite().equals(src.getSite())) {
                // Dual-output LUT: RW picked <L>_O as source, the locked route starts at <L>MUX. Make the routed
                // pin the primary source (PartialDFXRouter traces the PP's locked path back to it), keep the other
                // as alternate source.
                String pn = x.getSitePin().getPinName();
                SitePinInst np = src.getSiteInst().getSitePinInst(pn);
                if (np == null) np = n.createPin(pn, src.getSiteInst());
                if (np.equals(n.getAlternateSource())) n.setAlternateSource(null);
                n.setSource(np);
                // The old pin drives no routing (every PIP tree starts at the MUX pin) -> drop it; an <L>_O
                // alternate source next to a MUX primary NPEs in PartialRouter.saveRouting.
                boolean used = starts.contains(sn);
                if (!used) { try { n.removePin(src); } catch (RuntimeException e) { /* setSource already dropped it */ } } else n.setAlternateSource(src);
                fix += " pins=" + n.getPins() + " alt=" + n.getAlternateSource();
                srcFixed.add(n);
                fix = " FIXED source->" + np + (used ? " (old pin also routed, kept as alternate)" : " (old pin removed)");
                ok = true;
            }
            if (ok) ppOk++; else ppBad++;
            if (!ok || ppOk <= 3 || !fix.isEmpty() || (rmSrc && !inNet) || pp.getTerminalName().equals("io_request_bits_address[3]"))
                System.out.println("RW_PPDIAG " + (ok ? "ok " : "BAD ") + pp.getTerminalName() + " net=" + n.getName() + " pips=" + n.getPIPs().size()
                        + " ppInNet=" + inNet + " rmSrc=" + rmSrc + " walkEnd=" + x + " hops=" + hops + " src=" + src + " srcNode=" + sn
                        + " pins=" + n.getPins().size() + fix);
        }
        System.out.println("RW_PPDIAG ok=" + ppOk + " bad=" + ppBad + " sourceFixed=" + srcFixed.size());
        // Pre-route (maze, from the PPLOC) the RM sinks of nets whose source pin was re-pointed: PartialDFXRouter
        // abandons them in iteration 1 and lets other RM nets take the PPLOC's only exits (rwf_3 local).
        Set<Net> preNets = new HashSet<>(srcFixed);
        {
            Set<Net> withPP = new HashSet<>();
            for (PartitionPin pp : fst.getPartitionPins()) { Net n = fst.getNetFromPartitionPin(pp); if (n != null) withPP.add(n); }
            for (Net n : cand) {
                SitePinInst src = n.getSource();
                if (!n.isStaticNet() && !NetTools.isGlobalClock(n) && src != null && rmSis.contains(src.getSiteInst()) && !withPP.contains(n)) {
                    for (PIP p : n.getPIPs()) if (p.isPIPFixed()) { preNets.add(n); break; }
                }
            }
        }
        if (!preNets.isEmpty()) maze(fst, cand, preNets, rmSis, crs, "pre");
        holdDetour(fst, rmSis, crs);
        System.out.println("RW_FST candidate nets=" + cand.size() + " boundary=" + bnd + " clock=" + clk + " pinsToRoute=" + pins.size());
        t("prep");
        List<String> rargs = new ArrayList<>(Arrays.asList("--fixBoundingBox", "--useUTurnNodes", "--nonTimingDriven", "--verbose",
                // GND->VCC LUT-input inversion edits LUT INITs, which the RM-only extract would lose
                "--noInvertGndToVccForLutInputs"));
        if (pblock != null) { rargs.add("--pblock"); rargs.add(pblock); }
        System.out.println("RW_FST router args " + rargs);
        PartialDFXRouter.routeDesignWithUserDefinedArguments(fst, rargs.toArray(new String[0]), pins, false);
        t("PartialDFXRouter");
        // Pass 2, clock only, no pblock: the static clock tree enters the RP through RCLK/HDISTR nodes whose base
        // tile is outside the RP clock regions (rwf_3 local: all 882 RM clock pins left unrouted with --pblock).
        List<SitePinInst> clkPins = new ArrayList<>();
        for (Net n : cand) {
            if (!NetTools.isGlobalClock(n)) continue;
            DesignTools.updatePinsIsRouted(n);
            for (SitePinInst sp : n.getPins())
                if (!sp.isOutPin() && !sp.isRouted() && rmSis.contains(sp.getSiteInst())) clkPins.add(sp);
        }
        System.out.println("RW_FST clock pass: unrouted RM clock pins=" + clkPins.size());
        for (Net n : cand) {
            if (!NetTools.isGlobalClock(n)) continue;
            Map<String, Integer> ic = new TreeMap<>();
            for (PIP p : n.getPIPs()) {
                Node e = p.getEndNode();
                if (e == null) continue;
                ClockRegion cr = e.getTile().getClockRegion();
                ic.merge(e.getIntentCode() + "@" + (cr == null ? "-" : cr.getName()), 1, Integer::sum);
            }
            System.out.println("RW_CLKDIAG " + n.getName() + " pips=" + n.getPIPs().size() + " src=" + n.getSource());
            for (Map.Entry<String, Integer> e : ic.entrySet())
                if (e.getKey().contains("GLOBAL") || e.getKey().contains("X1Y0") || e.getKey().contains("X2Y0"))
                    System.out.println("RW_CLKDIAG   " + e.getKey() + " " + e.getValue());
        }
        if (!clkPins.isEmpty()) {
            List<String> cargs = new ArrayList<>(rargs.subList(0, rargs.indexOf("--noInvertGndToVccForLutInputs") + 1));
            PartialDFXRouter.routeDesignWithUserDefinedArguments(fst, cargs.toArray(new String[0]), clkPins, false);
            t("PartialDFXRouter clock pass");
        }

        restoreMaze();
        {
            Set<Node> ppNodes = new HashSet<>();
            for (PartitionPin pp : fst.getPartitionPins()) try { ppNodes.add(pp.getNode()); } catch (Exception e) { }
            int dropped = 0, nets = 0;
            for (Net n : cand) {
                if (n.isStaticNet() || NetTools.isGlobalClock(n)) continue;
                int d = dedupDrivers(n, ppNodes);
                if (d > 0) { dropped += d; nets++; }
            }
            System.out.println("RW_FST dedup: dropped " + dropped + " PIPs (double drivers / dangling) on " + nets + " nets");
        }
        // Pass 3: maze-route whatever is still unrouted on boundary nets.
        maze(fst, cand, null, rmSis, crs, "post");

        // Verify: unrouted pins, new PIPs outside the RP clock regions.
        int still = 0;
        long newPips = 0, outsidePips = 0;
        Map<String, Integer> outByNet = new TreeMap<>();
        Set<Net> touched = new LinkedHashSet<>(cand);
        Map<String, Integer> unByNet = new TreeMap<>();
        for (Net n : touched) {
            DesignTools.updatePinsIsRouted(n);
            for (SitePinInst sp : n.getPins()) {
                if (sp.isOutPin() || sp.isRouted()) continue;
                SitePinInst src = n.getSource();
                boolean rmDriven = !n.isStaticNet() && src != null && rmSis.contains(src.getSiteInst());
                if (!rmSis.contains(sp.getSiteInst()) && !rmDriven) continue;
                if (still++ < 10) System.out.println("RW_UNROUTED " + n.getName() + " " + sp);
                unByNet.merge(n.getName(), 1, Integer::sum);
            }
            int nn = 0;
            for (PIP p : n.getPIPs()) {
                if (p.isPIPFixed() && !MAZE_PIPS.contains(p)) continue;
                newPips++;
                nn++;
                ClockRegion cr = p.getTile().getClockRegion();
                if (cr == null || !crs.contains(cr.getName())) {
                    outsidePips++;
                    outByNet.merge(n.getName(), 1, Integer::sum);
                }
            }
        }
        for (Net n : touched) if (NetTools.isGlobalClock(n)) {
            int nn = 0; for (PIP p : n.getPIPs()) if (!p.isPIPFixed()) nn++;
            System.out.println("RW_CLKDIAG new clock pips " + n.getName() + " " + nn);
        }
        System.out.println("RW_FST after route: unrouted pins=" + still + " newPips=" + newPips
                + " newPipsOutsideRP=" + outsidePips);
        for (Map.Entry<String, Integer> e : unByNet.entrySet()) System.out.println("RW_UNROUTED_NET " + e.getValue() + " " + e.getKey());
        int k = 0;
        for (Map.Entry<String, Integer> e : outByNet.entrySet())
            if (k++ < 20) System.out.println("RW_OUTSIDE " + e.getValue() + " " + e.getKey());
        t("verify");

        // Extract: fresh RM design (placement), PIPs = the new (unfixed) PIPs of the matching fst nets.
        Design out = read(a[3], a[4]);
        int mapped = 0, unmapped = 0;
        long outPips = 0;
        for (Net n : out.getNets()) {
            List<PIP> np = new ArrayList<>();
            Net fn;
            if (n.isStaticNet()) {
                fn = fst.getStaticNet(n.getType());
            } else {
                EDIFHierNet hn = fst.getNetlist().getHierNetFromName(rp + "/" + n.getName());
                fn = hn == null ? null : fst.getNet(fst.getNetlist().getParentNet(hn).getHierarchicalNetName());
            }
            if (fn == null) {
                if (n.hasPIPs() || !n.getPins().isEmpty()) unmapped++;
                if (unmapped <= 10 && (n.hasPIPs() || !n.getPins().isEmpty())) System.out.println("RW_WARN unmapped " + n.getName());
                n.setPIPs(np);
                continue;
            }
            mapped++;
            for (PIP p : fn.getPIPs()) {
                if (p.isPIPFixed() && !MAZE_PIPS.contains(p)) continue;
                if (n.isStaticNet()) {
                    ClockRegion cr = p.getTile().getClockRegion();
                    if (cr == null || !crs.contains(cr.getName())) continue;
                }
                np.add(p);
            }
            n.setPIPs(np);
            outPips += np.size();
        }
        System.out.println("RW_FST extract nets mapped=" + mapped + " unmapped=" + unmapped + " pips=" + outPips);
        // Port partition pins = base PPLOC nodes (template = Vivado-extracted RP cell, else the pplocs file).
        Map<String, Node> want = new HashMap<>(pplocOf);
        List<PartitionPin> tplWirePPs = new ArrayList<>();
        if (tplDcp != null) {
            Design tpl = read(tplDcp, a[12]);
            want.clear();
            for (PartitionPin pp : tpl.getPartitionPins()) {
                try {
                    want.put(pp.getTerminalName(), Node.getNode(pp.getNode().toString(), out.getDevice()));
                } catch (Exception e) {
                    // clock partpins are site-pin wires (RCLK .../CLK_TEST_BUF_SITE_1_CLK_IN), not routing nodes
                    tplWirePPs.add(pp);
                }
            }
        }
        if (!tplWirePPs.isEmpty()) {
            Set<String> terms = new HashSet<>();
            for (PartitionPin pp : tplWirePPs) terms.add(pp.getTerminalName());
            for (PartitionPin pp : new ArrayList<>(out.getPartitionPins()))
                if (terms.contains(pp.getTerminalName())) out.removePartitionPin(pp);
            for (PartitionPin pp : tplWirePPs) {
                Tile tt = out.getDevice().getTile(pp.getTileName());
                PartitionPin np = new PartitionPin(tt, tt.getWireIndex(pp.getWireName()), pp.isFixed(), pp.isWireFixed());
                np.b(pp.getTerminalName());
                out.addPartitionPin(np);
                System.out.println("RW_FST out wire pp from template: " + np + " (template " + pp + ")");
            }
        }
        int ppSet = 0, ppAdd = 0;
        Set<String> seen = new HashSet<>();
        for (PartitionPin pp : out.getPartitionPins()) {
            Node w = want.get(pp.getTerminalName());
            seen.add(pp.getTerminalName());
            Node cur = null;
            try { cur = pp.getNode(); } catch (Exception e) { /* tile-level OOC pp */ }
            if (w != null && !w.equals(cur)) { pp.setNode(w); ppSet++; }
            if (w == null && !tplWirePPs.isEmpty()) continue;
            if (w == null) System.out.println("RW_WARN out pp left as is: " + pp.getTerminalName() + " " + pp.getTileName() + "/" + pp.getWireName());
        }
        EDIFCell top = out.getTopEDIFCell();
        for (Map.Entry<String, Node> e : want.entrySet()) {
            if (seen.contains(e.getKey())) continue;
            EDIFPort port = top.getPortByPortInstName(e.getKey());
            if (port == null) { System.out.println("RW_WARN no port " + e.getKey()); continue; }
            int idx = 0;
            if (port.isBus()) {
                for (int i = 0; i < port.getWidth(); i++) if (port.getPortInstNameFromPort(i).equals(e.getKey())) idx = i;
            }
            out.createPartitionPin(port, idx, e.getValue());
            ppAdd++;
        }
        System.out.println("RW_FST out partition pins=" + out.getPartitionPins().size() + " renoded=" + ppSet + " added=" + ppAdd);
        out.writeCheckpoint(a[9]);
        t("write " + Paths.get(a[9]).getFileName());
    }

    // ---------------------------------------------------------------- stitch
    static Node node(String s) {
        return Node.getNode(s.replaceAll("[{}]", "").trim(), dev);
    }

    static Device dev;

    /**
     * Prune dangling PIP branches of a net: repeatedly drop PIPs whose end node feeds nothing else in the
     * net and is not a kept terminal (sink site pin node or a partition-pin node).
     */
    static int pruneDangling(Net n, Set<Node> keep, boolean srcSide) {
        List<PIP> pips = new ArrayList<>(n.getPIPs());
        if (pips.isEmpty()) return 0;
        Map<Node, Integer> fanout = new HashMap<>();
        Map<Node, List<PIP>> byEnd = new HashMap<>();
        for (PIP p : pips) {
            fanout.merge(p.getStartNode(), 1, Integer::sum);
            byEnd.computeIfAbsent(p.getEndNode(), k -> new ArrayList<>()).add(p);
            if (p.isBidirectional()) {
                fanout.merge(p.getEndNode(), 1, Integer::sum);
            }
        }
        Set<Node> term = new HashSet<>(keep);
        for (SitePinInst sp : n.getPins()) {
            if (!sp.isOutPin()) term.add(sp.getConnectedNode());
        }
        Set<PIP> drop = new HashSet<>();
        Deque<Node> work = new ArrayDeque<>();
        for (Node e : byEnd.keySet()) if (!fanout.containsKey(e) && !term.contains(e)) work.add(e);
        while (!work.isEmpty()) {
            Node e = work.poll();
            List<PIP> in = byEnd.remove(e);
            if (in == null) continue;
            for (PIP p : in) {
                if (!drop.add(p)) continue;
                Node s = p.getStartNode();
                int f = fanout.merge(s, -1, Integer::sum);
                if (f <= 0 && !term.contains(s)) work.add(s);
            }
        }
        if (srcSide) {
            // Source side (non-static nets only): drop PIPs whose start node is neither driven by another
            // kept PIP nor the source site-pin node nor a kept terminal (orphaned old-RM driver branch).
            Map<Node, Integer> indeg = new HashMap<>();
            Map<Node, List<PIP>> byStart = new HashMap<>();
            for (PIP p : pips) {
                if (drop.contains(p)) continue;
                indeg.merge(p.getEndNode(), 1, Integer::sum);
                byStart.computeIfAbsent(p.getStartNode(), k -> new ArrayList<>()).add(p);
            }
            Set<Node> srcs = new HashSet<>(keep);
            for (SitePinInst sp : n.getPins()) if (sp.isOutPin()) srcs.add(sp.getConnectedNode());
            Deque<Node> w2 = new ArrayDeque<>();
            for (Node s : byStart.keySet()) if (!indeg.containsKey(s) && !srcs.contains(s)) w2.add(s);
            while (!w2.isEmpty()) {
                Node s = w2.poll();
                List<PIP> out = byStart.remove(s);
                if (out == null) continue;
                for (PIP p : out) {
                    if (!drop.add(p)) continue;
                    Node e = p.getEndNode();
                    int f = indeg.merge(e, -1, Integer::sum);
                    if (f <= 0 && !srcs.contains(e) && !term.contains(e)) w2.add(e);
                }
            }
        }
        if (!drop.isEmpty()) {
            List<PIP> keepP = new ArrayList<>();
            for (PIP p : pips) if (!drop.contains(p)) keepP.add(p);
            n.setPIPs(keepP);
        }
        return drop.size();
    }

    static void stitch(String[] a) throws Exception {
        String rp = a[5];
        boolean route = a.length <= 8 || a[8].equals("1");
        Design base = read(a[1], a[2]);
        dev = base.getDevice();
        Design rm = read(a[3], a[4]);
        stats("base", base);
        stats("rm", rm);
        t("stats");

        // Partition-pin nodes (from Vivado HD.ASSIGNED_PPLOCS of the base RP pins): the static-side
        // route of a boundary net ends there and must be kept as-is (static is locked; pr_verify).
        Set<Node> ppNodes = new HashSet<>();
        for (String l : Files.readAllLines(Paths.get(a[6]))) {
            String[] f = l.trim().split("\\s+", 2);
            if (f.length < 2) continue;
            for (String s : f[1].replaceAll("[{}]", " ").trim().split("\\s+")) {
                if (s.isEmpty()) continue;
                Node nd = Node.getNode(s, dev);
                if (nd == null) System.out.println("RW_WARN bad ppnode " + s);
                else ppNodes.add(nd);
            }
        }
        System.out.println("RW_STITCH ppnodes=" + ppNodes.size());

        // Snapshot routing of static nets and of every net touching the RP before makeBlackBox:
        // RapidWright's makeBlackBox unroutes GND/VCC design-wide and unroutes boundary nets back to
        // their branch point, both of which would modify locked static (AWS shell + FireSim CL) routing.
        Map<String, List<PIP>> snap = new HashMap<>();
        snap.put(base.getGndNet().getName(), new ArrayList<>(base.getGndNet().getPIPs()));
        snap.put(base.getVccNet().getName(), new ArrayList<>(base.getVccNet().getPIPs()));
        EDIFHierCellInst rpInst = base.getNetlist().getHierCellInstFromName(rp);
        Set<String> bnets = new HashSet<>();
        Map<String, String> renamed = new HashMap<>();
        for (EDIFPortInst pi : rpInst.getInst().getPortInsts()) {
            if (pi.getNet() == null) continue;
            EDIFHierNet hn = new EDIFHierNet(rpInst.getParent(), pi.getNet());
            String pn = base.getNetlist().getParentNet(hn).getHierarchicalNetName();
            Net n = base.getNet(pn);
            if (n != null && !n.isStaticNet()) {
                bnets.add(pn);
                snap.put(pn, new ArrayList<>(n.getPIPs()));
                // makeBlackBox renames a net whose driver was inside the RP to its outside segment
                if (pi.isOutput()) renamed.put(pn, hn.getHierarchicalNetName());
            }
        }
        System.out.println("RW_STITCH boundary nets=" + bnets.size());
        t("snapshot");

        // makeBlackBox -> unrouteGNDNetAndLUTSources also removes the intra-site routing of every LUT that
        // sources GND design-wide; record those (site, LUT out pin, site pin) to put back afterwards.
        List<Object[]> lutGnd = new ArrayList<>();
        Set<Node> gndStarts = new HashSet<>();
        for (PIP p : base.getGndNet().getPIPs()) gndStarts.add(p.getStartNode());
        for (Node nd : gndStarts) {
            SitePin sp = nd.getSitePin();
            if (sp != null && !sp.isInput() && com.xilinx.rapidwright.util.Utils.isSLICE(sp.getSite().getSiteTypeEnum())) {
                BELPin src = sp.getBELPin().getSourcePin();
                if (src.getBEL().isLUT()) lutGnd.add(new Object[]{sp.getSite(), src, sp.getBELPin()});
            }
        }
        System.out.println("RW_STITCH LUT GND sources=" + lutGnd.size());
        DesignTools.makeBlackBox(base, rp);
        t("makeBlackBox");
        int relut = 0;
        for (Object[] o : lutGnd) {
            SiteInst si = base.getSiteInstFromSite((Site) o[0]);
            if (si == null) continue;
            si.routeIntraSiteNet(base.getGndNet(), (BELPin) o[1], (BELPin) o[2]);
            relut++;
        }
        System.out.println("RW_STITCH LUT GND site routes restored=" + relut);

        // Restore snapshotted routing, then prune only branches that now lead nowhere (old RM sinks).
        long restored = 0, pruned = 0;
        for (Map.Entry<String, List<PIP>> e : snap.entrySet()) {
            Net n = base.getNet(e.getKey());
            if (n == null && renamed.containsKey(e.getKey())) n = base.getNet(renamed.get(e.getKey()));
            if (n == null) {
                System.out.println("RW_WARN net vanished " + e.getKey());
                continue;
            }
            n.setPIPs(e.getValue());
            restored += e.getValue().size();
            pruned += pruneDangling(n, ppNodes, !n.isStaticNet());
        }
        System.out.println("RW_STITCH restored pips=" + restored + " pruned=" + pruned);
        t("restore+prune");

        Set<PIP> rmPips = new HashSet<>();
        for (Net n : rm.getNets()) if (!n.isStaticNet()) rmPips.addAll(n.getPIPs());
        DesignTools.populateBlackBox(base, rp, rm, true);
        t("populateBlackBox");
        base.getNetlist().resetParentNetMap();
        DesignTools.makePhysNetNamesConsistent(base);
        DesignTools.createMissingSitePinInsts(base);
        // Boundary-net connectivity: PIPs not reachable from the net's source. RM-side ones (RM partition
        // pin != base PPLOC, e.g. after OOC implementation) are dropped so RWRoute reconnects those sinks;
        // static-side orphans are only reported (static routing is locked).
        int orphRm = 0, orphStatic = 0, discNets = 0;
        EDIFHierCellInst rpNow = base.getNetlist().getHierCellInstFromName(rp);
        Set<Net> bNow = new HashSet<>();
        for (EDIFPortInst pi : rpNow.getInst().getPortInsts()) {
            if (pi.getNet() == null) continue;
            EDIFHierNet hn = new EDIFHierNet(rpNow.getParent(), pi.getNet());
            Net n = base.getNet(base.getNetlist().getParentNet(hn).getHierarchicalNetName());
            if (n != null && !n.isStaticNet() && !n.isClockNet()) bNow.add(n);
        }
        for (Net n : bNow) {
            SitePinInst src = n.getSource();
            if (src == null || !n.hasPIPs()) continue;
            Map<Node, List<PIP>> byStart = new HashMap<>();
            for (PIP p : n.getPIPs()) byStart.computeIfAbsent(p.getStartNode(), k -> new ArrayList<>()).add(p);
            Set<PIP> reach = new HashSet<>();
            Deque<Node> q = new ArrayDeque<>();
            q.add(src.getConnectedNode());
            Set<Node> seen = new HashSet<>(q);
            while (!q.isEmpty()) {
                List<PIP> out = byStart.get(q.poll());
                if (out == null) continue;
                for (PIP p : out) {
                    reach.add(p);
                    if (seen.add(p.getEndNode())) q.add(p.getEndNode());
                }
            }
            if (reach.size() == n.getPIPs().size()) continue;
            discNets++;
            List<PIP> keepP = new ArrayList<>();
            for (PIP p : n.getPIPs()) {
                if (reach.contains(p)) keepP.add(p);
                else if (rmPips.contains(p)) orphRm++;
                else { orphStatic++; keepP.add(p); }
            }
            n.setPIPs(keepP);
            if (discNets <= 20) System.out.println("RW_DISC " + n.getName());
        }
        System.out.println("RW_STITCH boundary nets now=" + bNow.size() + " disconnected=" + discNets
                + " droppedRmOrphanPips=" + orphRm + " staticOrphanPips=" + orphStatic);
        int upd = DesignTools.updatePinsIsRouted(base);
        t("cleanup");
        List<SitePinInst> unrouted = PartialRouter.getUnroutedPins(base);
        System.out.println("RW_STITCH updatePinsIsRouted=" + upd + " unrouted pins=" + unrouted.size());
        int shown = 0;
        for (SitePinInst p : unrouted) {
            if (shown++ < 60) System.out.println("RW_UNROUTED " + p.getNet().getName() + " " + p);
        }
        stats("stitched", base);
        if (route && !unrouted.isEmpty()) {
            PartialRouter.routeDesignPartialNonTimingDriven(base, unrouted, false);
            t("rwroute partial");
            System.out.println("RW_STITCH after route unrouted=" + PartialRouter.getUnroutedPins(base).size());
        }
        base.writeCheckpoint(a[7]);
        t("write");
    }
}
