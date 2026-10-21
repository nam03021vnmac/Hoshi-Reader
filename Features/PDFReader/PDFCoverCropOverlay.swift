//
//  PDFCoverCropOverlay.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// A dashed box in the bookshelf's cover shape that's dragged over the page to pick the cover.
/// Only the box and its handles take touches, so the page can still be zoomed and scrolled around it.
struct PDFCoverCropOverlay: View {
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let onCancel: () -> Void
    /// The box in the overlay's coordinates, which are the PDF view's
    let onSave: (CGRect) -> Void

    @State private var box: CGRect = .zero
    @State private var dragStart: CGRect?

    private static let ratio = BookCover.aspectRatio
    private static let minWidth: CGFloat = 60
    private static let space = "coverCrop"

    private enum Corner: CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight

        var id: Self { self }
        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }

        func point(in rect: CGRect) -> CGPoint {
            CGPoint(x: isLeft ? rect.minX : rect.maxX, y: isTop ? rect.minY : rect.maxY)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(bounds)
                    path.addRect(box)
                }
                .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                Rectangle()
                    .strokeBorder(.white, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .contentShape(Rectangle())
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                    .gesture(moveGesture(in: bounds))

                ForEach(Corner.allCases) { corner in
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .frame(width: 16, height: 16)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .position(corner.point(in: box))
                        .gesture(resizeGesture(corner, in: bounds))
                }
            }
            .coordinateSpace(.named(Self.space))
            .onAppear {
                box = Self.initialBox(in: bounds)
            }
            .onChange(of: geometry.size) {
                box = Self.initialBox(in: bounds)
            }
        }
        .overlay(alignment: .top) {
            Text("Drag the box over the cover")
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .conditionalGlassEffect()
                .padding(.top, topPadding + 8)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            HStack {
                Button("Cancel", action: onCancel)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .conditionalGlassEffect()
                Spacer()
                Button("Use as Cover") {
                    onSave(box)
                }
                .fontWeight(.semibold)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .conditionalGlassEffect()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, bottomPadding)
        }
    }

    private static func initialBox(in bounds: CGRect) -> CGRect {
        let width = min(bounds.width * 0.6, bounds.height * 0.6 * ratio)
        let height = width / ratio
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    private func moveGesture(in bounds: CGRect) -> some Gesture {
        DragGesture(coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = dragStart ?? box
                dragStart = start
                var moved = start.offsetBy(dx: value.translation.width, dy: value.translation.height)
                moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
                moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
                box = moved
            }
            .onEnded { _ in
                dragStart = nil
            }
    }

    /// Resizes around the opposite corner, keeping the cover shape and staying on screen
    private func resizeGesture(_ corner: Corner, in bounds: CGRect) -> some Gesture {
        DragGesture(coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = dragStart ?? box
                dragStart = start
                let anchor = CGPoint(x: corner.isLeft ? start.maxX : start.minX, y: corner.isTop ? start.maxY : start.minY)
                let availableWidth = corner.isLeft ? anchor.x - bounds.minX : bounds.maxX - anchor.x
                let availableHeight = corner.isTop ? anchor.y - bounds.minY : bounds.maxY - anchor.y

                let wanted = max(abs(value.location.x - anchor.x), abs(value.location.y - anchor.y) * Self.ratio)
                let width = max(min(wanted, availableWidth, availableHeight * Self.ratio), Self.minWidth)
                let height = width / Self.ratio
                box = CGRect(
                    x: corner.isLeft ? anchor.x - width : anchor.x,
                    y: corner.isTop ? anchor.y - height : anchor.y,
                    width: width,
                    height: height
                )
            }
            .onEnded { _ in
                dragStart = nil
            }
    }
}
